import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:build/build.dart';
import 'package:build_runner/src/bootstrap/build_process_state.dart'
    show buildProcessState;
import 'package:crypto/crypto.dart' show Digest;
import 'package:build_runner/src/build/asset_content.dart' show AssetContent;
import 'package:build_runner/src/build/build_step_impl.dart' show BuildStepImpl;
import 'package:build_runner/src/build/input_tracker.dart' show InputTracker;
import 'package:build_runner/src/logging/build_log.dart' show buildLog;
import 'package:build_runner/src/logging/build_log_logger.dart'
    show BuildLogLogger;
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';

import 'compiler_package_config.dart';
import 'frontend_binary_resolver.dart' show buildRunnerAcceleratorVersion;
import 'manifest/trigger_worker.dart' show writeManifestTriggers;
import 'protocol.dart';
import 'remote_build_step.dart';
import 'resolver_host.dart' show ResolverInitializationProfile;
import 'resolver_metrics.dart';
import 'resolver_reads.dart';
import 'trigger_evaluator.dart';
import 'worker_factory_probe.dart';
import 'worker_runtime.dart';

export 'worker_runtime.dart' show SharedPartEncoder, SharedPartStepFactory;

final _metricsEnabled =
    Platform.environment['BUILD_RUNNER_ACCELERATOR_METRICS'] == '1';

/// Serves framed builder IPC, or the manifest/probe mode selected by arguments.
Future<void> runWorker({
  required Map<String, BuilderFactory> catalog,
  SharedPartEncoder? sharedPartEncoder,
  SharedPartStepFactory? sharedPartStepFactory,
  List<String> arguments = const [],
  Map<String, PostProcessBuilderFactory> postProcessCatalog =
      const <String, PostProcessBuilderFactory>{},
}) async {
  if ((arguments.length >= 3 && arguments.length <= 5) &&
      arguments.first == '--manifest-triggers') {
    await writeManifestTriggers(
      arguments[1],
      arguments[2],
      configKey: arguments.length >= 4
          ? jsonDecode(arguments[3]) as String?
          : null,
      buildWorkspace: arguments.length == 5
          ? jsonDecode(arguments[4]) as bool
          : false,
    );
    return;
  }
  if (arguments.isNotEmpty) {
    if (arguments.length != 3 || arguments.first != '--factory-probe') {
      stderr.writeln(
        'usage: worker [--factory-probe <requests> <result> | '
        '--manifest-triggers <root> <result> [config-json] [workspace-json]]',
      );
      exitCode = 64;
      return;
    }
    runWorkerFactoryProbe(
      requestsPath: arguments[1],
      resultPath: arguments[2],
      catalog: catalog,
      postProcessCatalog: postProcessCatalog,
    );
    return;
  }
  // stdout is the binary IPC channel. Capture build_runner diagnostics so
  // package logging can never corrupt a frame.
  buildLog.configuration = buildLog.configuration.rebuild((config) {
    config.onLog = (record) {
      if (record.level >= Level.WARNING) {
        stderr.writeln('[${record.level.name}] ${record.message}');
        if (record.error != null) stderr.writeln(record.error);
        if (record.stackTrace != null) stderr.writeln(record.stackTrace);
      }
    };
  });
  final packageConfigTimer = _metricsEnabled ? (Stopwatch()..start()) : null;
  final packageConfig = await _loadPackageConfig();
  final resolverProfile = ResolverInitializationProfile(
    enabled: _metricsEnabled,
  )..packageConfigLoadUs = packageConfigTimer?.elapsedMicroseconds ?? 0;
  final runtime = WorkerRuntime(
    packageConfig,
    resolverProfile,
    sharedPartEncoder: sharedPartEncoder,
    sharedPartStepFactory: sharedPartStepFactory,
  );
  final reader = FrameReader(stdin);
  final writer = FrameWriter(stdout);
  try {
    while (true) {
      final rawMessage = await reader.next();
      if (rawMessage == null) return;
      try {
        final message = WorkerMessage.decode(
          rawMessage,
          previousBatchBlockedAssets: runtime.transport.batchBlockedAssets,
          assetDictionary: runtime.transport.assetDictionary,
        );
        switch (message) {
          case WorkerInitializeMessage initialize:
            if (Directory(initialize.root).resolveSymbolicLinksSync() !=
                Directory.current.resolveSymbolicLinksSync()) {
              throw StateError(
                'initialize root does not match worker workspace',
              );
            }
            runtime.transport.resetOnInitialize();
            runtime.retainedOutputGuard = initialize.retainedOutputGuard;
            await runtime.startBuild(
              initialize.package,
              phaseCount: initialize.phaseCount,
              inputRestrictions: initialize.inputRestrictions,
            );
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'initialized',
              'accelerator_version': buildRunnerAcceleratorVersion,
              'id': initialize.id,
              'capabilities': <String>[
                ...catalog.keys,
                'asset-rpc-v1',
                'asset-rpc-binary-read-v1',
                'build-result-binary-v1',
                'optional-builder-demand-v1',
                'shared-blocked-assets-v1',
                'blocked-assets-reuse-v1',
                'batch-shared-fields-v1',
                'asset-id-interning-v1',
                'asset-digests-v1',
                'api-fingerprints-v1',
                'reset-overlay-blob-v1',
                'build-runner-current-v1',
                'retained-output-guard-v1',
                if (runtime.supportsSharedParts) 'shared-library-parts-v1',
              ],
            });
          case WorkerResetMessage reset:
            await runtime.reset();
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'reset',
              'id': reset.id,
            });
          case WorkerResetResolverMessage resetResolver:
            await runtime.resetResolver(
              updatedSources: resetResolver.updatedSources
                  .map(AssetId.parse)
                  .toSet(),
              deletedSources: resetResolver.deletedSources
                  .map(AssetId.parse)
                  .toSet(),
              updatedCache: resetResolver.updatedCache
                  .map(AssetId.parse)
                  .toSet(),
              deletedCache: resetResolver.deletedCache
                  .map(AssetId.parse)
                  .toSet(),
              incremental: resetResolver.incremental,
              overlayBlob: resetResolver.overlayBlob,
            );
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'reset_resolver',
              'id': resetResolver.id,
            });
          case WorkerApiFingerprintQueryMessage query:
            // The query reads assets through the same RPC channel as a
            // build action, so it runs inside an IO action scope; with
            // no build started there is nothing to read through and
            // every entry is simply unavailable.
            if (!runtime.buildStarted) {
              await writer.send(<String, dynamic>{
                'v': 1,
                'type': 'api_fingerprints',
                'id': query.id,
                'results': await runtime.apiFingerprintQuery(query.entries),
              });
              break;
            }
            final queryRpc = RpcSession(
              reader,
              writer,
              buildId: query.id as int,
              phase: runtime.phaseCount,
              postProcess: false,
              onControlMessage: (nested) => _handleNestedBuild(
                nested,
                reader,
                writer,
                runtime,
                catalog,
                postProcessCatalog,
              ),
            );
            runtime.io.beginAction(
              rpc: queryRpc,
              package: query.entries.isEmpty
                  ? ''
                  : AssetId.parse(query.entries.first.asset).package,
              primaryInput: null,
              blockedAssets: const <AssetId>{},
            );
            try {
              await writer.send(<String, dynamic>{
                'v': 1,
                'type': 'api_fingerprints',
                'id': query.id,
                'results': await runtime.apiFingerprintQuery(query.entries),
              });
            } finally {
              runtime.io.endAction();
            }
          case WorkerBuildMessage build:
            await _handleBuild(
              build.request,
              reader,
              writer,
              runtime,
              catalog,
              postProcessCatalog,
            );
          case WorkerBuildBatchMessage buildBatch:
            runtime.transport.applyAssetDigestUpdates(
              buildBatch.assetDigestUpdates,
            );
            await _handleBuildBatch(
              buildBatch,
              reader,
              writer,
              runtime,
              catalog,
              postProcessCatalog,
            );
          case UnsupportedWorkerMessage unsupported:
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'error',
              'id': unsupported.id,
              'error': 'Unsupported worker message: ${unsupported.type}',
            });
        }
      } catch (error, stack) {
        await writer.send(<String, dynamic>{
          'v': 1,
          'type': 'error',
          'id': rawMessage['id'],
          'error': '$error',
          'stack': '$stack',
        });
      }
    }
  } finally {
    await runtime.close();
  }
}

class _BuildProfile {
  _BuildProfile({
    required this.builder,
    required this.input,
    required this.resolverProfile,
    this.traceEnabled = false,
  }) : _total = Stopwatch()..start();

  final bool traceEnabled;
  final String builder;
  final String input;
  final Stopwatch _total;
  String status = 'error';
  int factoryUs = 0;
  int resolverGetUs = 0;
  int resolverGetCalls = 0;
  int resolverFirstGetUs = 0;
  int runBuilderUs = 0;
  int? runBuilderStartUs;
  List<Map<String, int>>? resolverSpans;
  int resolverReadsUs = 0;
  int resultAssemblyUs = 0;
  int outputCount = 0;
  int readCount = 0;
  int resolverReadCount = 0;
  int globCount = 0;
  final Map<String, int> activityUs = <String, int>{};
  final ResolverInitializationProfile resolverProfile;

  void recordResolverGet(int elapsedUs, {required bool first}) {
    if (traceEnabled) {
      final spans = resolverSpans ??= <Map<String, int>>[];
      if (spans.length < 16) {
        spans.add({
          'offset_us': _total.elapsedMicroseconds - elapsedUs,
          'duration_us': elapsedUs,
        });
      }
    }
    resolverGetUs += elapsedUs;
    resolverGetCalls++;
    if (first) resolverFirstGetUs += elapsedUs;
  }

  void emit() {
    if (!_metricsEnabled) return;
    stderr.writeln(
      'Dart metrics: ${jsonEncode(<String, dynamic>{'builder': builder, 'input': input, 'status': status, 'total_us': _total.elapsedMicroseconds, 'factory_us': factoryUs, 'resolver_get_us': resolverGetUs, 'resolver_get_calls': resolverGetCalls, 'resolver_first_get_us': resolverFirstGetUs, 'package_config_load_us': resolverProfile.packageConfigLoadUs, 'resolver_constructor_us': resolverProfile.resolverConstructorUs, 'resolver_sdk_summary_us': resolverProfile.sdkSummaryUs, 'resolver_sdk_summary_lock_wait_us': resolverProfile.sdkSummaryLockWaitUs, 'resolver_sdk_summary_after_lock_us': resolverProfile.sdkSummaryAfterLockUs, 'resolver_sdk_summary_read_us': resolverProfile.sdkSummaryReadUs, 'driver_create_us': resolverProfile.driverCreateUs, 'build_resolver_ctor_us': resolverProfile.buildResolverCtorUs, 'resolver_post_sdk_summary_us': resolverProfile.resolverPostSdkSummaryUs, 'run_builder_us': runBuilderUs, 'resolver_reads_us': resolverReadsUs, 'result_assembly_us': resultAssemblyUs, 'outputs': outputCount, 'reads': readCount, 'resolver_reads': resolverReadCount, 'glob_reads': globCount})}',
    );
    stderr.writeln(
      'Dart action metrics: ${jsonEncode(<String, dynamic>{'builder': builder, 'input': input, 'status': status, ...resolverActionMetrics.toJson(), 'driver_creations': resolverProfile.driverCreations, 'resolver_replacements': resolverProfile.resolverReplacements, 'activity_us': activityUs})}',
    );
  }
}

/// Snapshot of build_runner `TimedActivity` buckets in microseconds.
Map<String, int> _activityDurations() {
  final result = <String, int>{};
  for (final entry in buildLog.activities.durations(phaseName: null).entries) {
    result[entry.key.name] = entry.value.inMicroseconds;
  }
  return result;
}

const _retainedApiUnsupported =
    'digest/resolver APIs with retained modified outputs are unsupported; run dart run build_runner directly if needed';

class _RetainedOutputBuildStep extends BuildStepImpl {
  _RetainedOutputBuildStep({
    required super.inputId,
    required super.expectedOutputs,
    required super.inputTracker,
    required super.buildFilesystem,
    required super.phase,
    required super.resolvers,
    required super.resourceManager,
    super.reportUnusedAssets,
  });

  bool unsupportedDigestUsed = false;

  @override
  Future<Digest> digest(AssetId id, {bool track = true}) async {
    unsupportedDigestUsed = true;
    throw UnsupportedError(_retainedApiUnsupported);
  }
}

class _TrackingResolvers extends Resolvers {
  _TrackingResolvers(this._delegate, {this.retainedOutputGuard = false});

  final Resolvers _delegate;
  final bool retainedOutputGuard;
  bool wasUsed = false;

  @override
  Future<ReleasableResolver> get(BuildStep buildStep) {
    wasUsed = true;
    if (retainedOutputGuard) {
      throw UnsupportedError(_retainedApiUnsupported);
    }
    return _delegate.get(buildStep);
  }

  @override
  void reset() => _delegate.reset();
}

class _ProfilingResolvers extends Resolvers {
  _ProfilingResolvers(this._delegate, this._runtime, this._profile);

  final Resolvers _delegate;
  final WorkerRuntime _runtime;
  final _BuildProfile _profile;

  @override
  Future<ReleasableResolver> get(BuildStep buildStep) async {
    final first = !_runtime.resolverInitialized;
    final timer = Stopwatch()..start();
    try {
      final resolver = await _delegate.get(buildStep);
      if (first) {
        _runtime.resolverInitialized = true;
        _runtime.resolverProfile.recordFirstGet(
          timer.elapsedMicroseconds,
          builder: _profile.builder,
          input: _profile.input,
        );
        _runtime.resolverProfile.emit();
      }
      _profile.recordResolverGet(timer.elapsedMicroseconds, first: first);
      return resolver;
    } catch (_) {
      _profile.recordResolverGet(timer.elapsedMicroseconds, first: false);
      rethrow;
    }
  }

  @override
  void reset() => _delegate.reset();
}

Future<PackageConfig> _loadPackageConfig() async {
  // A compiled executable can omit the isolate's package-config URI (notably
  // on Windows). Workers always run in the workspace root, which is checked
  // against the initialize request before any build action is accepted.
  final hasCompatibilityConfig = hasCompilerPackageConfig('.');
  var packageConfigUri = hasCompatibilityConfig
      ? pubPackageConfigFile('.').uri
      : await Isolate.packageConfig;
  if (packageConfigUri == null || hasCompatibilityConfig) {
    // Compile with the backport, but keep original package roots for builder
    // reads, resolver assets, and SDK summary identity.
    packageConfigUri ??= pubPackageConfigFile('.').uri;
    // build_runner's SDK summary generator uses its process state rather than
    // the PackageConfig passed to our resolver. Seed it through the same API
    // that build_runner uses when starting an AOT build isolate.
    buildProcessState.deserializeAndSet(
      jsonEncode({'packageConfigUri': packageConfigUri.toString()}),
    );
  }
  return loadPackageConfigUri(packageConfigUri);
}

Future<void> _handleBuild(
  WorkerBuildRequest request,
  FrameReader reader,
  FrameWriter writer,
  WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  await writer.sendBuildResult(
    await _runSingleBuild(
      request,
      reader,
      writer,
      runtime,
      builderCatalog,
      postProcessCatalog,
    ),
  );
}

Future<void> _handleNestedBuild(
  WorkerBuildRequest request,
  FrameReader reader,
  FrameWriter writer,
  WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  try {
    await writer.sendBuildResult(
      await _runSingleBuild(
        request,
        reader,
        writer,
        runtime,
        builderCatalog,
        postProcessCatalog,
      ),
    );
  } catch (error, stack) {
    await writer.sendBuildResult(<String, dynamic>{
      'v': 1,
      'type': 'build_result',
      'id': request.id,
      'status': 'error',
      'outputs': <dynamic>[],
      'deleted': <String>[],
      'reads': <String>[],
      'stock_inputs': <String>[],
      'stock_globs': <String, List<String>>{},
      'resolver_reads': <String>[],
      'resolver_content_reads': <String>[],
      'resolver_entrypoints': <String>[],
      'resolver_used': false,
      'dep_graph': <String, List<String>>{},
      'api_fingerprints': <String, String?>{},
      'glob_reads': <dynamic>[],
      'diagnostics': <dynamic>[],
      'error': '$error',
      'stack': '$stack',
    });
  }
}

// Single demand calls need the same transitive resolver evidence as batches.
// Keep graph emission outside _runBuild so batch results retain their shared
// graph and nested single results can each deliver the edges they discovered.
Future<JsonMap> _runSingleBuild(
  WorkerBuildRequest request,
  FrameReader reader,
  FrameWriter writer,
  WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  final result = await _runBuild(
    request,
    reader,
    writer,
    runtime,
    builderCatalog,
    postProcessCatalog,
  );
  result['dep_graph'] = runtime.encodeDepGraphDelta(
    (result['resolver_entrypoints'] as List<String>).map(AssetId.parse).toSet(),
  );
  result['api_fingerprints'] = runtime.encodeApiFingerprintsDelta();
  return result;
}

Future<void> _handleBuildBatch(
  WorkerBuildBatchMessage message,
  FrameReader reader,
  FrameWriter writer,
  WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  final results = <JsonMap>[];
  final blockedAssets = runtime.transport.resolveBatchBlockedAssets(
    message.blockedAssets,
  );
  runtime.batchResolverEntrypoints.clear();
  for (final request in message.requests) {
    results.add(
      await _runBuild(
        request,
        reader,
        writer,
        runtime,
        builderCatalog,
        postProcessCatalog,
        inheritedBlockedAssets: blockedAssets,
      ),
    );
  }
  await writer.sendBuildResult(<String, dynamic>{
    'v': 1,
    'type': 'build_batch_result',
    'id': message.id,
    'results': results,
    'dep_graph': runtime.encodeDepGraphDelta(runtime.batchResolverEntrypoints),
    'api_fingerprints': runtime.encodeApiFingerprintsDelta(),
  });
}

Future<JsonMap> _runBuild(
  WorkerBuildRequest request,
  FrameReader reader,
  FrameWriter writer,
  WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog, {
  Set<AssetId>? inheritedBlockedAssets,
}) async {
  // API fingerprint learning follows this action's opt-in (ADR 0056):
  // dep walks during the action record fingerprints only for
  // builders the build opted in to the API cutoff. A lazy asset read
  // can suspend this action and run a producer action on the same
  // worker, so the caller's setting is restored afterwards.
  final previousLearning = runtime.resolver.fingerprintLearningEnabled;
  runtime.resolver.setFingerprintLearningEnabled(request.apiCutoff);
  try {
    return await _runBuildAction(
      request,
      reader,
      writer,
      runtime,
      builderCatalog,
      postProcessCatalog,
      inheritedBlockedAssets: inheritedBlockedAssets,
    );
  } finally {
    runtime.resolver.setFingerprintLearningEnabled(previousLearning);
  }
}

Future<JsonMap> _runBuildAction(
  WorkerBuildRequest request,
  FrameReader reader,
  FrameWriter writer,
  WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog, {
  Set<AssetId>? inheritedBlockedAssets,
}) async {
  final traceStart = request.traceparent == null || request.otelReportId == null
      ? null
      : DateTime.now().microsecondsSinceEpoch;
  final builderId = request.builder;
  final inputName = request.input;
  final isPostProcess = request.isPostProcess;
  final isRoot = request.isRoot;
  final profile = _BuildProfile(
    builder: builderId,
    input: inputName,
    resolverProfile: runtime.resolverProfile,
    traceEnabled: traceStart != null,
  );
  var actionStarted = false;
  var resolverUsed = false;
  try {
    final input = AssetId.parse(inputName);
    final actionLog = buildLog.loggerForOther(builderId, contextId: input);
    final blockedAssets =
        inheritedBlockedAssets ??
        request.blockedAssets.map(AssetId.parse).toSet();
    final options = Map<String, dynamic>.from(request.options);
    final triggers = request.triggers
        .map(
          (trigger) =>
              NormalizedBuildTrigger(kind: trigger.kind, value: trigger.value),
        )
        .toList(growable: false);
    if (isPostProcess && triggers.isNotEmpty) {
      throw StateError('triggers are unsupported for post-process builders');
    }
    final rpc = RpcSession(
      reader,
      writer,
      buildId: request.id,
      phase: request.phase,
      postProcess: isPostProcess,
      onControlMessage: (nested) => _handleNestedBuild(
        nested,
        reader,
        writer,
        runtime,
        builderCatalog,
        postProcessCatalog,
      ),
    );
    runtime.io.beginAction(
      rpc: rpc,
      package: input.package,
      primaryInput: isPostProcess ? input : null,
      blockedAssets: blockedAssets,
    );
    actionStarted = true;
    resolverActionMetrics.beginAction();
    final activitySnapshot = _metricsEnabled
        ? _activityDurations()
        : const <String, int>{};
    final drained = await runtime.drainPendingDepLoadsForPhase(request.phase);
    final drainReads = drained.reads;
    final drainResolverReads = drained.resolverReads;
    final deleted = <AssetId>{};
    BuildStepImpl? step;
    JsonMap? sharedPart;
    InputTracker? triggerInputTracker;
    var triggered = true;
    if (!isPostProcess && options['run_only_if_triggered'] == true) {
      triggerInputTracker = InputTracker(
        runtime.io.filesystem,
        primaryInput: input,
        builderLabel: builderId,
      );
      triggered = await evaluateBuildTriggers(
        triggers: triggers,
        primaryInput: input,
        phase: request.phase,
        filesystem: runtime.buildFilesystem,
        inputTracker: triggerInputTracker,
      );
    }
    final runBuilderTimer = Stopwatch()..start();
    if (traceStart != null)
      profile.runBuilderStartUs = profile._total.elapsedMicroseconds;
    try {
      if (!triggered) {
        profile.status = 'not_triggered';
      } else if (isPostProcess) {
        final factory = postProcessCatalog[builderId];
        if (factory == null) {
          throw StateError('Unknown post-process builder: $builderId');
        }
        final instanceKey = _instanceKey(request);
        var postProcessBuilder = runtime.postProcessBuilders[instanceKey];
        if (postProcessBuilder == null) {
          final factoryTimer = Stopwatch()..start();
          postProcessBuilder = factory(BuilderOptions(options, isRoot: isRoot));
          profile.factoryUs = factoryTimer.elapsedMicroseconds;
          runtime.postProcessBuilders[instanceKey] = postProcessBuilder;
        }
        final postProcessStep = RemotePostProcessBuildStep(
          inputId: input,
          io: runtime.io,
          deletePrimaryInput: deleted.add,
        );
        await BuildLogLogger.scopeLogAsync(() async {
          try {
            await postProcessBuilder!.build(postProcessStep);
          } finally {
            await postProcessStep.complete();
          }
        }, actionLog);
      } else {
        final trackedResolver = _TrackingResolvers(
          runtime.resolver,
          retainedOutputGuard: runtime.retainedOutputGuard,
        );
        final resolver = (_metricsEnabled || traceStart != null)
            ? _ProfilingResolvers(trackedResolver, runtime, profile)
            : trackedResolver;
        final factory = builderCatalog[builderId];
        if (factory == null) {
          throw StateError('Unknown builder: $builderId');
        }
        final instanceKey = _instanceKey(request);
        var builder = runtime.builders[instanceKey];
        if (builder == null) {
          final factoryTimer = Stopwatch()..start();
          builder = factory(BuilderOptions(options, isRoot: isRoot));
          profile.factoryUs = factoryTimer.elapsedMicroseconds;
          runtime.builders[instanceKey] = builder;
        }
        final inputTracker = InputTracker(
          runtime.io.filesystem,
          primaryInput: input,
          builderLabel: builderId,
        );
        final createStep = runtime.retainedOutputGuard
            ? _RetainedOutputBuildStep.new
            : BuildStepImpl.new;
        if (request.partPhaseIndex != null && runtime.retainedOutputGuard) {
          throw UnsupportedError(_retainedApiUnsupported);
        }
        final expectedOutputs = [
          for (final output in request.allowedOutputs) AssetId.parse(output),
        ];
        final BuildStepImpl activeStep;
        if (request.partPhaseIndex == null) {
          activeStep = createStep(
            inputId: input,
            expectedOutputs: expectedOutputs,
            inputTracker: inputTracker,
            buildFilesystem: runtime.buildFilesystem,
            phase: request.phase,
            resolvers: resolver,
            resourceManager: runtime.resourceManager,
          );
        } else {
          final create = runtime.sharedPartStepFactory;
          if (create == null)
            throw StateError('Shared-part worker factory is missing');
          activeStep = create(
            input,
            expectedOutputs,
            inputTracker,
            runtime.buildFilesystem,
            request.phase,
            request.partPhaseIndex!,
            resolver,
            runtime.resourceManager,
          );
        }
        step = activeStep;
        await BuildLogLogger.scopeLogAsync(() async {
          try {
            await builder!.build(activeStep);
            if (request.partPhaseIndex != null) {
              final encode = runtime.sharedPartEncoder;
              if (encode == null)
                throw StateError('Shared-part worker codec is missing');
              sharedPart = await encode(activeStep, builderId);
            }
          } finally {
            try {
              await activeStep.complete();
            } finally {
              // Latch the unsupported API even if a builder catches its exception
              // or fails later. Never publish the builder's catch-path output.
              if ((activeStep is _RetainedOutputBuildStep &&
                      activeStep.unsupportedDigestUsed) ||
                  (trackedResolver.retainedOutputGuard &&
                      trackedResolver.wasUsed)) {
                throw UnsupportedError(_retainedApiUnsupported);
              }
            }
          }
        }, actionLog);
        resolverUsed = trackedResolver.wasUsed;
      }
      if (actionLog.errors.isNotEmpty) {
        throw StateError(
          'Builder $builderId logged errors: ${actionLog.errors.join('\n')}',
        );
      }
    } finally {
      profile.runBuilderUs = runBuilderTimer.elapsedMicroseconds;
    }

    if (triggered) {
      final resolverReadsTimer = Stopwatch()..start();
      await collectResolverReads(
        runtime.io,
        runtime.packageConfig,
        runtime.resolverDependencyCache,
        excludeReads: {...drainReads, ...drainResolverReads},
        // The staged map holds no declared outputs and this build's own
        // produced outputs are excluded here, so a digest only ever names
        // snapshot content (ADR 0054, Snapshot semantics).
        frontendDigestFor: (asset) => runtime.producedOutputs.containsKey(asset)
            ? null
            : runtime.transport.assetDigests[asset.toString()],
      );
      profile.resolverReadsUs = resolverReadsTimer.elapsedMicroseconds;
    }

    final resultAssemblyTimer = Stopwatch()..start();
    final outputs = <Map<String, dynamic>>[
      if (isPostProcess)
        for (final entry in runtime.io.outputs.entries)
          <String, dynamic>{'asset': entry.key.toString(), 'bytes': entry.value}
      else if (step != null)
        for (final entry in step.outputs.entries)
          <String, dynamic>{
            'asset': entry.key.toString(),
            'bytes': entry.value.bytes,
          },
    ];
    if (isPostProcess) {
      for (final entry in runtime.io.outputs.entries) {
        runtime.producedOutputs[entry.key] = AssetContent.bytes(entry.value);
      }
    } else if (step != null) {
      runtime.producedOutputs.addAll(step.outputs);
    }
    final observedReads = drainReads.isEmpty
        ? runtime.io.observedReads
        : runtime.io.observedReads.difference(drainReads);
    final resolverObservedReads = drainResolverReads.isEmpty
        ? runtime.io.resolverObservedReads
        : runtime.io.resolverObservedReads.difference(drainResolverReads);
    // The step's InputTracker also records the resolver's internal
    // readability probes: libraryFor preloads its target through the
    // step, which tracks it as an input even though the builder
    // never read it. Assets the IO attributed to the resolver
    // channel alone (and did not also surface as direct reads or
    // glob results) are resolver observations, so they come out of
    // the direct set again; an asset read both ways stays direct.
    final resolverOnlyReads = resolverObservedReads
        .difference(observedReads)
        .difference(runtime.io.observedGlobResults);
    final readsSet = <String>{
      input.toString(),
      if (triggerInputTracker != null)
        ...triggerInputTracker.inputs.map((id) => id.toString()),
      if (step != null) ...step.inputTracker.inputs.map((id) => id.toString()),
      ...observedReads.map((id) => id.toString()),
      ...runtime.io.observedGlobResults.map((id) => id.toString()),
    }..removeAll(resolverOnlyReads.map((id) => id.toString()));
    final reads = readsSet.toList()..sort();
    final resolverReads = <String>{
      if (triggered && step != null)
        ...step.inputTracker.resolverEntrypoints.map((id) => id.toString()),
      // Resolver invalidation keeps the full union: direct reads,
      // plus the loads recorded separately as resolver machinery
      // reads (ADR 0056). Only `reads` above is direct-only.
      if (triggered) ...observedReads.map((id) => id.toString()),
      if (triggered) ...resolverObservedReads.map((id) => id.toString()),
    }.toList()..sort();
    final resolverEntrypoints = <AssetId>{
      if (triggered && step != null) ...step.inputTracker.resolverEntrypoints,
    };
    runtime.batchResolverEntrypoints.addAll(resolverEntrypoints);
    final globReads = runtime.io.observedGlobs.toList()
      ..sort((left, right) {
        final packageOrder = left.package.compareTo(right.package);
        return packageOrder != 0
            ? packageOrder
            : left.pattern.compareTo(right.pattern);
      });
    if (_metricsEnabled) {
      final after = _activityDurations();
      for (final entry in after.entries) {
        final delta = entry.value - (activitySnapshot[entry.key] ?? 0);
        if (delta != 0) profile.activityUs[entry.key] = delta;
      }
    }
    profile.resultAssemblyUs = resultAssemblyTimer.elapsedMicroseconds;
    profile.outputCount = outputs.length;
    profile.readCount = reads.length;
    profile.resolverReadCount = resolverReads.length;
    profile.globCount = globReads.length;
    profile.status = triggered ? 'success' : 'not_triggered';
    return <String, dynamic>{
      'v': 1,
      'type': 'build_result',
      'id': request.id,
      'status': profile.status,
      // Exclude batch preparation and IPC from scheduler cost learning.
      'execution_us': profile._total.elapsedMicroseconds,
      'outputs': outputs,
      if (sharedPart != null) 'shared_part': sharedPart,
      'deleted': <String>[for (final asset in deleted) asset.toString()]
        ..sort(),
      'reads': reads,
      // Preserve stock InputTracker iteration order for filtered reuse. The
      // broader reads above also include analyzer/prefetch bookkeeping.
      'stock_inputs': <String>[
        if (triggerInputTracker != null)
          ...triggerInputTracker.inputs.map((id) => id.toString()),
        if (step != null)
          ...step.inputTracker.inputs.map((id) => id.toString()),
      ],
      'stock_globs': <String, List<String>>{
        for (final entry in runtime.io.observedGlobMembers.entries)
          '${entry.key.package}|${entry.key.pattern}': [
            for (final asset in entry.value) asset.toString(),
          ],
      },
      'resolver_reads': resolverReads,
      'resolver_content_reads': <String>[
        if (step != null)
          for (final id in runtime.resolver.contentReadsFor(step))
            id.toString(),
      ]..sort(),
      'resolver_entrypoints': <String>[
        for (final id in resolverEntrypoints) id.toString(),
      ],
      'resolver_used': resolverUsed,
      'glob_reads': <Map<String, String>>[
        if (step != null)
          for (final glob in step.inputTracker.globsEvaluated)
            <String, String>{'package': glob.package, 'pattern': glob.glob}
        else
          for (final glob in globReads)
            <String, String>{'package': glob.package, 'pattern': glob.pattern},
      ],
      'diagnostics': <dynamic>[],
    };
  } finally {
    if (actionStarted) runtime.io.endAction();
    profile.emit();
    if (traceStart != null) {
      // A fixed-size report, with no asset IDs, options or source text. The
      // native SDK exports this as a child of the propagated batch context.
      await writer.send(<String, dynamic>{
        'v': 1,
        'type': 'otel_action',
        'traceparent': request.traceparent,
        'otel_report_id': request.otelReportId,
        'start_us': traceStart,
        'duration_us': profile._total.elapsedMicroseconds,
        'success':
            profile.status == 'success' || profile.status == 'not_triggered',
        'run_builder_us': profile.runBuilderUs,
        'run_builder_start_us': profile.runBuilderStartUs,
        'resolver_spans': profile.resolverSpans,
        'resolver_get_us': profile.resolverGetUs,
        'resolver_get_calls': profile.resolverGetCalls,
        'outputs': profile.outputCount,
        'reads': profile.readCount,
        'resolver_reads': profile.resolverReadCount,
      });
    }
  }
}

String _instanceKey(WorkerBuildRequest request) => request.instanceKey;
