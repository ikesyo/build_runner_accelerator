import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:build_runner/src/build/asset_content.dart' show AssetContent;
import 'package:build_runner/src/build/build_step_impl.dart' show BuildStepImpl;
import 'package:build_runner/src/build/input_tracker.dart' show InputTracker;
import 'package:build_runner/src/build_plan/placeholders.dart'
    show Placeholders;
import 'package:build_runner/src/logging/build_log.dart' show buildLog;
import 'package:build_runner/src/logging/build_log_logger.dart'
    show BuildLogLogger;
import 'package:crypto/crypto.dart' show Digest;

import 'protocol.dart';
import 'remote_build_step.dart';
import 'resolver_host.dart' show ResolverInitializationProfile;
import 'resolver_metrics.dart';
import 'resolver_reads.dart';
import 'trigger_evaluator.dart';
import 'worker_runtime.dart';

class WorkerActionRunner {
  WorkerActionRunner({
    required this.reader,
    required this.writer,
    required this.runtime,
    required this.builderCatalog,
    required this.postProcessCatalog,
  });

  final FrameReader reader;
  final FrameWriter writer;
  final WorkerRuntime runtime;
  final Map<String, BuilderFactory> builderCatalog;
  final Map<String, PostProcessBuilderFactory> postProcessCatalog;

  Future<void> handleBuild(WorkerBuildRequest request) async {
    await writer.sendBuildResult(await _runSingleBuild(request));
  }

  Future<void> handleNestedBuild(WorkerBuildRequest request) async {
    try {
      await writer.sendBuildResult(await _runSingleBuild(request));
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
  Future<JsonMap> _runSingleBuild(WorkerBuildRequest request) async {
    final result = await _runBuild(request);
    result['dep_graph'] = runtime.encodeDepGraphDelta(
      (result['resolver_entrypoints'] as List<String>)
          .map(AssetId.parse)
          .toSet(),
    );
    result['api_fingerprints'] = runtime.encodeApiFingerprintsDelta();
    return result;
  }

  Future<void> _prefetchBatchInputs(
    WorkerBuildBatchMessage message,
    Set<AssetId> blockedAssets,
  ) async {
    if (!runtime.buildStarted ||
        message.requests.length < 2 ||
        message.requests.first.isPostProcess) {
      return;
    }
    final candidates = <AssetId>[];
    final seen = <AssetId>{};
    for (final request in message.requests) {
      final AssetId id;
      try {
        id = AssetId.parse(request.input);
      } on Object {
        continue;
      }
      if (!seen.add(id) ||
          Placeholders.isPlaceholderPath(id.path) ||
          blockedAssets.contains(id) ||
          runtime.buildState.committedContentOf(id) != null ||
          runtime.readCache.containsKey(id) ||
          runtime.pathCache.containsKey(id) ||
          runtime.readableCache.contains(id)) {
        continue;
      }
      candidates.add(id);
    }
    // A single uncached input already resolves in one `can_read` RPC carrying
    // its filesystem path, and avoids any RPC when the action does not read it.
    if (candidates.length < 2) return;
    final first = message.requests.first;
    final prefetchRpc = RpcSession(
      reader,
      writer,
      buildId: first.id,
      phase: first.phase,
      postProcess: false,
    );
    runtime.io.beginAction(
      rpc: prefetchRpc,
      package: candidates.first.package,
      primaryInput: null,
      blockedAssets: blockedAssets,
    );
    try {
      await runtime.io.prefetchAssets(candidates);
    } finally {
      runtime.io.endAction();
    }
  }

  Future<void> handleBuildBatch(WorkerBuildBatchMessage message) async {
    final results = <JsonMap>[];
    final blockedAssets = runtime.transport.resolveBatchBlockedAssets(
      message.blockedAssets,
    );
    final preferGlobCache = message.requests.length >= 2;
    runtime.batchResolverEntrypoints.clear();
    await _prefetchBatchInputs(message, blockedAssets);
    for (final request in message.requests) {
      results.add(
        await _runBuild(
          request,
          inheritedBlockedAssets: blockedAssets,
          preferGlobCache: preferGlobCache,
        ),
      );
    }
    await writer.sendBuildResult(<String, dynamic>{
      'v': 1,
      'type': 'build_batch_result',
      'id': message.id,
      'results': results,
      'dep_graph': runtime.encodeDepGraphDelta(
        runtime.batchResolverEntrypoints,
      ),
      'api_fingerprints': runtime.encodeApiFingerprintsDelta(),
    });
  }

  Future<JsonMap> _runBuild(
    WorkerBuildRequest request, {
    Set<AssetId>? inheritedBlockedAssets,
    bool preferGlobCache = false,
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
        inheritedBlockedAssets: inheritedBlockedAssets,
        preferGlobCache: preferGlobCache,
      );
    } finally {
      runtime.resolver.setFingerprintLearningEnabled(previousLearning);
    }
  }

  Future<JsonMap> _runBuildAction(
    WorkerBuildRequest request, {
    Set<AssetId>? inheritedBlockedAssets,
    bool preferGlobCache = false,
  }) async {
    final traceStart =
        request.traceparent == null || request.otelReportId == null
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
            (trigger) => NormalizedBuildTrigger(
              kind: trigger.kind,
              value: trigger.value,
            ),
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
        onControlMessage: handleNestedBuild,
      );
      runtime.io.beginAction(
        rpc: rpc,
        package: input.package,
        primaryInput: isPostProcess ? input : null,
        blockedAssets: blockedAssets,
        preferGlobCache: preferGlobCache,
      );
      actionStarted = true;
      resolverActionMetrics.beginAction();
      final activitySnapshot = runtime.resolverProfile.enabled
          ? _activityDurations()
          : const <String, int>{};
      final drained = await runtime.drainPendingDepLoadsForPhase(request.phase);
      final drainReads = drained.reads;
      final drainResolverReads = drained.resolverReads;
      final triggerResult = await _evaluateTriggers(
        isPostProcess: isPostProcess,
        options: options,
        triggers: triggers,
        input: input,
        builderId: builderId,
        phase: request.phase,
      );
      final triggered = triggerResult.triggered;
      var deleted = const <AssetId>{};
      BuildStepImpl? step;
      JsonMap? sharedPart;
      final runBuilderTimer = Stopwatch()..start();
      if (traceStart != null) {
        profile.runBuilderStartUs = profile.elapsedUs;
      }
      try {
        if (!triggered) {
          profile.status = 'not_triggered';
        } else if (isPostProcess) {
          deleted = await _executePostProcessAction(
            request: request,
            input: input,
            builderId: builderId,
            options: options,
            isRoot: isRoot,
            actionLog: actionLog,
            profile: profile,
          );
        } else {
          final result = await _executeNormalAction(
            request: request,
            input: input,
            builderId: builderId,
            options: options,
            isRoot: isRoot,
            actionLog: actionLog,
            profile: profile,
            traceEnabled: traceStart != null,
          );
          step = result.step;
          sharedPart = result.sharedPart;
          resolverUsed = result.resolverUsed;
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
          frontendDigestFor: (asset) =>
              runtime.producedOutputs.containsKey(asset)
              ? null
              : runtime.transport.assetDigests[asset.toString()],
        );
        profile.resolverReadsUs = resolverReadsTimer.elapsedMicroseconds;
      }

      return _assembleActionResult(
        request: request,
        input: input,
        isPostProcess: isPostProcess,
        triggered: triggered,
        step: step,
        sharedPart: sharedPart,
        deleted: deleted,
        resolverUsed: resolverUsed,
        triggerInputTracker: triggerResult.tracker,
        drainReads: drainReads,
        drainResolverReads: drainResolverReads,
        activitySnapshot: activitySnapshot,
        profile: profile,
      );
    } finally {
      if (actionStarted) runtime.io.endAction();
      profile.emit();
      if (traceStart != null) {
        await _emitOtelAction(request, profile, traceStart);
      }
    }
  }

  Future<({bool triggered, InputTracker? tracker})> _evaluateTriggers({
    required bool isPostProcess,
    required Map<String, dynamic> options,
    required List<NormalizedBuildTrigger> triggers,
    required AssetId input,
    required String builderId,
    required int phase,
  }) async {
    if (isPostProcess || options['run_only_if_triggered'] != true) {
      return (triggered: true, tracker: null);
    }
    final tracker = InputTracker(
      runtime.io.filesystem,
      primaryInput: input,
      builderLabel: builderId,
    );
    final triggered = await evaluateBuildTriggers(
      triggers: triggers,
      primaryInput: input,
      phase: phase,
      filesystem: runtime.buildFilesystem,
      inputTracker: tracker,
    );
    return (triggered: triggered, tracker: tracker);
  }

  Future<Set<AssetId>> _executePostProcessAction({
    required WorkerBuildRequest request,
    required AssetId input,
    required String builderId,
    required Map<String, dynamic> options,
    required bool isRoot,
    required BuildLogLogger actionLog,
    required _BuildProfile profile,
  }) async {
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
    final deleted = <AssetId>{};
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
    return deleted;
  }

  Future<({BuildStepImpl step, JsonMap? sharedPart, bool resolverUsed})>
  _executeNormalAction({
    required WorkerBuildRequest request,
    required AssetId input,
    required String builderId,
    required Map<String, dynamic> options,
    required bool isRoot,
    required BuildLogLogger actionLog,
    required _BuildProfile profile,
    required bool traceEnabled,
  }) async {
    final trackedResolver = _TrackingResolvers(
      runtime.resolver,
      retainedOutputGuard: runtime.retainedOutputGuard,
    );
    final resolver = (runtime.resolverProfile.enabled || traceEnabled)
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
      if (create == null) {
        throw StateError('Shared-part worker factory is missing');
      }
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
    JsonMap? sharedPart;
    await BuildLogLogger.scopeLogAsync(() async {
      try {
        await builder!.build(activeStep);
        if (request.partPhaseIndex != null) {
          final encode = runtime.sharedPartEncoder;
          if (encode == null) {
            throw StateError('Shared-part worker codec is missing');
          }
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
    return (
      step: activeStep,
      sharedPart: sharedPart,
      resolverUsed: trackedResolver.wasUsed,
    );
  }

  JsonMap _assembleActionResult({
    required WorkerBuildRequest request,
    required AssetId input,
    required bool isPostProcess,
    required bool triggered,
    required BuildStepImpl? step,
    required JsonMap? sharedPart,
    required Set<AssetId> deleted,
    required bool resolverUsed,
    required InputTracker? triggerInputTracker,
    required Set<AssetId> drainReads,
    required Set<AssetId> drainResolverReads,
    required Map<String, int> activitySnapshot,
    required _BuildProfile profile,
  }) {
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
    if (runtime.resolverProfile.enabled) {
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
      'execution_us': profile.elapsedUs,
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
  }

  Future<void> _emitOtelAction(
    WorkerBuildRequest request,
    _BuildProfile profile,
    int traceStart,
  ) {
    // A fixed-size report, with no asset IDs, options or source text. The
    // native SDK exports this as a child of the propagated batch context.
    return writer.send(<String, dynamic>{
      'v': 1,
      'type': 'otel_action',
      'traceparent': request.traceparent,
      'otel_report_id': request.otelReportId,
      'start_us': traceStart,
      'duration_us': profile.elapsedUs,
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

  String _instanceKey(WorkerBuildRequest request) => request.instanceKey;
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

  int get elapsedUs => _total.elapsedMicroseconds;

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
    if (!resolverProfile.enabled) return;
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
