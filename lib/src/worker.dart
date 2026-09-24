import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:build/build.dart';
import 'package:build_runner/src/build/build_step_impl.dart' show BuildStepImpl;
import 'package:build_runner/src/build/input_tracker.dart' show InputTracker;
import 'worker_resolvers.dart' show WorkerResolversImpl;
import 'package:build_runner/src/build_plan/build_packages.dart'
    show BuildPackages;
import 'package:build_runner/src/logging/build_log.dart' show buildLog;
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';

import 'package:build_runner/src/build/asset_content.dart' show AssetContent;
import 'package:build_runner/src/build_plan/build_inputs.dart' show BuildInputs;

import 'current_build_runtime.dart';
import 'protocol.dart';
import 'remote_build_step.dart';
import 'resolver_host.dart';
import 'resolver_reads.dart';
import 'trigger_evaluator.dart';

final _metricsEnabled =
    Platform.environment['BUILD_RUNNER_ACCELERATOR_METRICS'] == '1';

Future<void> runWorker({
  required Map<String, BuilderFactory> catalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog =
      const <String, PostProcessBuilderFactory>{},
}) async {
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
  final runtime = _WorkerRuntime(packageConfig, resolverProfile);
  final reader = FrameReader(stdin);
  final writer = FrameWriter(stdout);
  try {
    while (true) {
      final rawMessage = await reader.next();
      if (rawMessage == null) return;
      try {
        final message = WorkerMessage.decode(rawMessage);
        switch (message) {
          case WorkerInitializeMessage initialize:
            await runtime.startBuild(
              initialize.package,
              phaseCount: initialize.phaseCount,
            );
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'initialized',
              'id': initialize.id,
              'capabilities': <String>[
                ...catalog.keys,
                'asset-rpc-v1',
                'asset-rpc-binary-read-v1',
                'build-result-binary-v1',
                'optional-builder-demand-v1',
                'shared-blocked-assets-v1',
                'build-runner-current-v1',
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
              incremental: resetResolver.incremental,
            );
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'reset_resolver',
              'id': resetResolver.id,
            });
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

class _WorkerRuntime {
  _WorkerRuntime(this.packageConfig, this.resolverProfile)
    : resolver = createResolver(packageConfig, resolverProfile);

  final PackageConfig packageConfig;
  final ResolverInitializationProfile resolverProfile;
  final WorkerResolversImpl resolver;
  final ResourceManager resourceManager = ResourceManager();
  final Map<AssetId, List<int>> readCache = <AssetId, List<int>>{};
  final Set<AssetId> readableCache = <AssetId>{};
  final ResolverDependencyCache resolverDependencyCache =
      ResolverDependencyCache();

  /// Bytes of outputs this worker produced during the current build.
  ///
  /// Source outputs stay in the Rust overlay until the final commit, so they
  /// cannot be re-read from disk after a phase commit; the worker already
  /// holds their bytes from the build results it returned.
  final Map<AssetId, AssetContent> producedOutputs = <AssetId, AssetContent>{};
  final Map<String, Builder> builders = <String, Builder>{};
  final Map<String, PostProcessBuilder> postProcessBuilders =
      <String, PostProcessBuilder>{};

  String? currentPackage;
  late RemoteAssetReaderWriter io;
  late BuildPackages buildPackages;
  late RemoteBuildState buildState;
  late RemoteBuilderFilesystem buildFilesystem;
  bool _buildStarted = false;
  bool resolverInitialized = false;
  int _phaseCount = 1;

  /// Starts a new build series for [package].
  Future<void> startBuild(String package, {required int phaseCount}) async {
    if (_buildStarted) {
      await resourceManager.disposeAll();
      resolver.reset();
      _buildStarted = false;
    }
    currentPackage = package;
    _phaseCount = phaseCount < 1 ? 1 : phaseCount;
    _clearPerBuildState();
    await _startBuild();
  }

  /// Ends the previous build and starts the next one with a fresh build
  /// filesystem while retaining Resource identity and reusable read caches only
  /// where current worker semantics allow it.
  Future<void> reset() async {
    if (!_buildStarted) return;
    await resourceManager.disposeAll();
    resolver.reset();
    _buildStarted = false;
    _clearPerBuildState();
    await _startBuild();
  }

  /// Reopens the current resolver's analysis model after Rust commits a
  /// source-output phase. A new BuilderFilesystem is required because current
  /// build_runner allows a filesystem to register its content listener once.
  ///
  /// With [incremental], the analyzer's in-memory filesystem and the loaded
  /// library-cycle graph are kept: only [updatedSources] are refreshed (the
  /// worker supplies their new contents itself since they are not committed
  /// to disk yet) and [deletedSources] evicted, so unchanged sources do not
  /// get re-analyzed. Only valid when this worker produced every committed
  /// output itself.
  Future<void> resetResolver({
    Set<AssetId> updatedSources = const <AssetId>{},
    Set<AssetId> deletedSources = const <AssetId>{},
    bool incremental = false,
  }) async {
    if (!_buildStarted) return;
    resolverDependencyCache.clear();
    if (!incremental) {
      resolver.reset();
      _buildStarted = false;
      await _startBuild(clearReadCaches: false, clearBuilders: false);
      return;
    }
    for (final id in updatedSources.followedBy(deletedSources)) {
      readCache.remove(id);
      readableCache.remove(id);
    }
    for (final id in deletedSources) {
      producedOutputs.remove(id);
    }
    // Updated assets this worker did not produce itself were spooled by Rust
    // under the workspace overlay directory (multi-worker builds only).
    // If any content is unavailable, fall back to a clean reset rather than
    // exposing a missing file to the analyzer.
    for (final id in updatedSources) {
      final spoolFile = File(
        '${Directory.current.path}/.dart_tool/build_runner_accelerator/'
        'overlay/${id.package}/${id.path}',
      );
      if (spoolFile.existsSync()) {
        // The spool is the current overlay value, even if this worker produced
        // an earlier version of the same asset in a previous phase.
        producedOutputs[id] = AssetContent.bytes(spoolFile.readAsBytesSync());
      } else if (producedOutputs.containsKey(id)) {
        // In a single-worker build the current value is already in memory.
      } else {
        resolver.reset();
        _buildStarted = false;
        await _startBuild(clearReadCaches: false, clearBuilders: false);
        return;
      }
    }
    resolver.reset(clearGraph: false);
    _buildStarted = false;
    await _startBuild(
      buildInputs: BuildInputs((builder) {
        builder.cleanBuild = false;
        builder.updatedSources.addAll(updatedSources);
        builder.deletedSources.addAll(deletedSources);
      }),
      clearReadCaches: false,
      clearBuilders: false,
    );
  }

  Future<void> close() async {
    if (_buildStarted) {
      await resourceManager.disposeAll();
      resolver.reset();
      _buildStarted = false;
    }
    await resourceManager.beforeExit();
  }

  void _clearPerBuildState() {
    readCache.clear();
    readableCache.clear();
    resolverDependencyCache.clear();
    producedOutputs.clear();
    builders.clear();
    postProcessBuilders.clear();
  }

  Future<void> _startBuild({
    BuildInputs? buildInputs,
    bool clearReadCaches = false,
    bool clearBuilders = false,
  }) async {
    if (clearReadCaches) {
      readCache.clear();
      readableCache.clear();
    }
    if (clearBuilders) {
      builders.clear();
      postProcessBuilders.clear();
    }
    final package = currentPackage;
    if (package == null) {
      throw StateError('Worker build started without an initialized package');
    }
    buildPackages = buildPackagesFor(packageConfig, package);
    io = RemoteAssetReaderWriter(
      readCache: readCache,
      readableCache: readableCache,
    );
    buildState = RemoteBuildState(
      buildPackages.packages.keys.toSet(),
      phaseCount: _phaseCount,
      committedContents: producedOutputs,
    );
    buildFilesystem = RemoteBuilderFilesystem(
      buildPackages: buildPackages,
      buildState: buildState,
      readerWriter: io,
    );
    await resolver.takeLockAndStartBuild(
      builderFilesystem: buildFilesystem,
      buildInputs: buildInputs ?? cleanBuildInputs(),
    );
    _buildStarted = true;
  }
}

class _BuildProfile {
  _BuildProfile({
    required this.builder,
    required this.input,
    required this.resolverProfile,
  }) : _total = Stopwatch()..start();

  final String builder;
  final String input;
  final Stopwatch _total;
  String status = 'error';
  int factoryUs = 0;
  int resolverGetUs = 0;
  int resolverGetCalls = 0;
  int resolverFirstGetUs = 0;
  int runBuilderUs = 0;
  int resolverReadsUs = 0;
  int resultAssemblyUs = 0;
  int outputCount = 0;
  int readCount = 0;
  int resolverReadCount = 0;
  int globCount = 0;
  final ResolverInitializationProfile resolverProfile;

  void recordResolverGet(int elapsedUs, {required bool first}) {
    resolverGetUs += elapsedUs;
    resolverGetCalls++;
    if (first) resolverFirstGetUs += elapsedUs;
  }

  void emit() {
    if (!_metricsEnabled) return;
    stderr.writeln(
      'Dart metrics: ${jsonEncode(<String, dynamic>{'builder': builder, 'input': input, 'status': status, 'total_us': _total.elapsedMicroseconds, 'factory_us': factoryUs, 'resolver_get_us': resolverGetUs, 'resolver_get_calls': resolverGetCalls, 'resolver_first_get_us': resolverFirstGetUs, 'package_config_load_us': resolverProfile.packageConfigLoadUs, 'resolver_constructor_us': resolverProfile.resolverConstructorUs, 'resolver_sdk_summary_us': resolverProfile.sdkSummaryUs, 'resolver_sdk_summary_lock_wait_us': resolverProfile.sdkSummaryLockWaitUs, 'resolver_sdk_summary_after_lock_us': resolverProfile.sdkSummaryAfterLockUs, 'resolver_post_sdk_summary_us': resolverProfile.resolverPostSdkSummaryUs, 'run_builder_us': runBuilderUs, 'resolver_reads_us': resolverReadsUs, 'result_assembly_us': resultAssemblyUs, 'outputs': outputCount, 'reads': readCount, 'resolver_reads': resolverReadCount, 'glob_reads': globCount})}',
    );
  }
}

class _TrackingResolvers extends Resolvers {
  _TrackingResolvers(this._delegate);

  final Resolvers _delegate;
  bool wasUsed = false;

  @override
  Future<ReleasableResolver> get(BuildStep buildStep) {
    wasUsed = true;
    return _delegate.get(buildStep);
  }

  @override
  void reset() => _delegate.reset();
}

class _ProfilingResolvers extends Resolvers {
  _ProfilingResolvers(this._delegate, this._runtime, this._profile);

  final Resolvers _delegate;
  final _WorkerRuntime _runtime;
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
  final packageConfigUri = await Isolate.packageConfig;
  if (packageConfigUri == null) {
    throw StateError('The worker isolate has no package_config.json');
  }
  return loadPackageConfigUri(packageConfigUri);
}

Future<void> _handleBuild(
  WorkerBuildRequest request,
  FrameReader reader,
  FrameWriter writer,
  _WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  await writer.sendBuildResult(
    await _runBuild(
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
  _WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  try {
    await writer.sendBuildResult(
      await _runBuild(
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
      'resolver_reads': <String>[],
      'resolver_used': false,
      'glob_reads': <dynamic>[],
      'diagnostics': <dynamic>[],
      'error': '$error',
      'stack': '$stack',
    });
  }
}

Future<void> _handleBuildBatch(
  WorkerBuildBatchMessage message,
  FrameReader reader,
  FrameWriter writer,
  _WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  final results = <JsonMap>[];
  final blockedAssets = message.blockedAssets.map(AssetId.parse).toSet();
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
  });
}

Future<JsonMap> _runBuild(
  WorkerBuildRequest request,
  FrameReader reader,
  FrameWriter writer,
  _WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog, {
  Set<AssetId>? inheritedBlockedAssets,
}) async {
  final builderId = request.builder;
  final inputName = request.input;
  final isPostProcess = request.isPostProcess;
  final isRoot = request.isRoot;
  final profile = _BuildProfile(
    builder: builderId,
    input: inputName,
    resolverProfile: runtime.resolverProfile,
  );
  var actionStarted = false;
  var resolverUsed = false;
  try {
    final input = AssetId.parse(inputName);
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
    final deleted = <AssetId>{};
    BuildStepImpl? step;
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
      try {
        await postProcessBuilder.build(postProcessStep);
      } finally {
        await postProcessStep.complete();
      }
    } else {
      final trackedResolver = _TrackingResolvers(runtime.resolver);
      final resolver = _metricsEnabled
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
      step = BuildStepImpl(
        inputId: input,
        expectedOutputs: [
          for (final output in request.allowedOutputs) AssetId.parse(output),
        ],
        inputTracker: inputTracker,
        buildFilesystem: runtime.buildFilesystem,
        phase: request.phase,
        resolvers: resolver,
        resourceManager: runtime.resourceManager,
      );
      try {
        await builder.build(step);
      } finally {
        await step.complete();
      }
      resolverUsed = trackedResolver.wasUsed;
    }
    profile.runBuilderUs = runBuilderTimer.elapsedMicroseconds;

    if (triggered) {
      final resolverReadsTimer = Stopwatch()..start();
      await collectResolverReads(
        runtime.io,
        runtime.packageConfig,
        runtime.resolverDependencyCache,
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
    final reads = <String>{
      input.toString(),
      if (triggerInputTracker != null)
        ...triggerInputTracker.inputs.map((id) => id.toString()),
      if (step != null) ...step.inputTracker.inputs.map((id) => id.toString()),
      ...runtime.io.observedReads.map((id) => id.toString()),
      ...runtime.io.observedGlobResults.map((id) => id.toString()),
    }.toList()..sort();
    final resolverReads = <String>{
      if (triggered && step != null)
        ...step.inputTracker.resolverEntrypoints.map((id) => id.toString()),
      if (triggered) ...runtime.io.observedReads.map((id) => id.toString()),
    }.toList()..sort();
    final globReads = runtime.io.observedGlobs.toList()
      ..sort((left, right) {
        final packageOrder = left.package.compareTo(right.package);
        return packageOrder != 0
            ? packageOrder
            : left.pattern.compareTo(right.pattern);
      });
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
      'outputs': outputs,
      'deleted': <String>[for (final asset in deleted) asset.toString()]
        ..sort(),
      'reads': reads,
      'resolver_reads': resolverReads,
      'resolver_used': resolverUsed,
      'glob_reads': <Map<String, String>>[
        for (final glob in globReads)
          <String, String>{'package': glob.package, 'pattern': glob.pattern},
      ],
      'diagnostics': <dynamic>[],
    };
  } finally {
    if (actionStarted) runtime.io.endAction();
    profile.emit();
  }
}

String _instanceKey(WorkerBuildRequest request) {
  final explicit = request.instanceKey;
  if (explicit != null) return explicit;
  return '${request.kind}|${request.builder}|${jsonEncode(request.options)}';
}
