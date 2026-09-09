import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:build/build.dart';
import 'package:build_runner/src/build/build_step_impl.dart' show BuildStepImpl;
import 'package:build_runner/src/build/input_tracker.dart' show InputTracker;
import 'package:build_runner/src/build/resolver/resolvers_impl.dart'
    show ResolversImpl;
import 'package:build_runner/src/build_plan/build_packages.dart'
    show BuildPackages;
import 'package:build_runner/src/logging/build_log.dart' show buildLog;
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';

import 'current_build_runtime.dart';
import 'protocol.dart';
import 'remote_build_step.dart';
import 'resolver_host.dart';
import 'resolver_reads.dart';

final _metricsEnabled =
    Platform.environment['FAST_BUILD_RUNNER_METRICS'] == '1';

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
      final message = await reader.next();
      if (message == null) return;
      try {
        switch (message['type']) {
          case 'initialize':
            final package = message['package'];
            if (package is! String || package.isEmpty) {
              throw const FormatException(
                'initialize requires a non-empty package',
              );
            }
            final rawPhaseCount = message['phase_count'];
            final phaseCount = rawPhaseCount is num
                ? (rawPhaseCount.toInt() < 1 ? 1 : rawPhaseCount.toInt())
                : 1;
            await runtime.startBuild(package, phaseCount: phaseCount);
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'initialized',
              'id': message['id'],
              'capabilities': <String>[
                ...catalog.keys,
                'asset-rpc-v1',
                'asset-rpc-binary-read-v1',
                'build-result-binary-v1',
                'build-runner-current-v1',
              ],
            });
          case 'reset':
            await runtime.reset();
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'reset',
              'id': message['id'],
            });
          case 'reset_resolver':
            await runtime.resetResolver();
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'reset_resolver',
              'id': message['id'],
            });
          case 'build':
            await _handleBuild(
              message,
              reader,
              writer,
              runtime,
              catalog,
              postProcessCatalog,
            );
          case 'build_batch':
            await _handleBuildBatch(
              message,
              reader,
              writer,
              runtime,
              catalog,
              postProcessCatalog,
            );
          default:
            await writer.send(<String, dynamic>{
              'v': 1,
              'type': 'error',
              'id': message['id'],
              'error': 'Unsupported worker message: ${message['type']}',
            });
        }
      } catch (error, stack) {
        await writer.send(<String, dynamic>{
          'v': 1,
          'type': 'error',
          'id': message['id'],
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
  final ResolversImpl resolver;
  final ResourceManager resourceManager = ResourceManager();
  final Map<AssetId, List<int>> readCache = <AssetId, List<int>>{};
  final Set<AssetId> readableCache = <AssetId>{};
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
  Future<void> resetResolver() async {
    if (!_buildStarted) return;
    resolver.reset();
    _buildStarted = false;
    await _startBuild(clearReadCaches: false, clearBuilders: false);
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
    builders.clear();
    postProcessBuilders.clear();
  }

  Future<void> _startBuild({
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
    );
    buildFilesystem = RemoteBuilderFilesystem(
      buildPackages: buildPackages,
      buildState: buildState,
      readerWriter: io,
    );
    await resolver.takeLockAndStartBuild(
      builderFilesystem: buildFilesystem,
      buildInputs: cleanBuildInputs(),
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
  JsonMap message,
  FrameReader reader,
  FrameWriter writer,
  _WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  await writer.sendBuildResult(
    await _runBuild(
      message,
      reader,
      writer,
      runtime,
      builderCatalog,
      postProcessCatalog,
    ),
  );
}

Future<void> _handleBuildBatch(
  JsonMap message,
  FrameReader reader,
  FrameWriter writer,
  _WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  final rawRequests = message['requests'];
  if (rawRequests is! List) {
    throw FormatException('build_batch requests must be a list');
  }
  final results = <JsonMap>[];
  for (final rawRequest in rawRequests) {
    if (rawRequest is! Map) {
      throw FormatException('build_batch request must be an object');
    }
    results.add(
      await _runBuild(
        rawRequest.cast<String, dynamic>(),
        reader,
        writer,
        runtime,
        builderCatalog,
        postProcessCatalog,
      ),
    );
  }
  await writer.sendBuildResult(<String, dynamic>{
    'v': 1,
    'type': 'build_batch_result',
    'id': message['id'],
    'results': results,
  });
}

Future<JsonMap> _runBuild(
  JsonMap message,
  FrameReader reader,
  FrameWriter writer,
  _WorkerRuntime runtime,
  Map<String, BuilderFactory> builderCatalog,
  Map<String, PostProcessBuilderFactory> postProcessCatalog,
) async {
  final builderId = message['builder'] as String;
  final inputName = message['input'] as String;
  final isPostProcess = message['kind'] == 'post_process';
  final profile = _BuildProfile(
    builder: builderId,
    input: inputName,
    resolverProfile: runtime.resolverProfile,
  );
  try {
    final input = AssetId.parse(inputName);
    final rawAllowedOutputs = message['allowed_outputs'] ?? const <dynamic>[];
    if (rawAllowedOutputs is! List) {
      throw FormatException('build allowed_outputs must be a list');
    }
    final blockedAssets = isPostProcess
        ? <AssetId>{}
        : rawAllowedOutputs
              .map((asset) => AssetId.parse(asset as String))
              .toSet();
    final options = Map<String, dynamic>.from(
      (message['options'] as Map<dynamic, dynamic>?) ?? <dynamic, dynamic>{},
    );
    final rpc = RpcSession(reader, writer);
    runtime.io.beginAction(
      rpc: rpc,
      package: input.package,
      primaryInput: isPostProcess ? input : null,
      blockedAssets: blockedAssets,
    );
    final resolver = _metricsEnabled
        ? _ProfilingResolvers(runtime.resolver, runtime, profile)
        : runtime.resolver;
    final runBuilderTimer = Stopwatch()..start();
    final deleted = <AssetId>{};
    BuildStepImpl? step;

    if (isPostProcess) {
      final factory = postProcessCatalog[builderId];
      if (factory == null) {
        throw StateError('Unknown post-process builder: $builderId');
      }
      final instanceKey = _instanceKey(message);
      var postProcessBuilder = runtime.postProcessBuilders[instanceKey];
      if (postProcessBuilder == null) {
        final factoryTimer = Stopwatch()..start();
        postProcessBuilder = factory(BuilderOptions(options));
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
      final factory = builderCatalog[builderId];
      if (factory == null) {
        throw StateError('Unknown builder: $builderId');
      }
      final instanceKey = _instanceKey(message);
      var builder = runtime.builders[instanceKey];
      if (builder == null) {
        final factoryTimer = Stopwatch()..start();
        builder = factory(BuilderOptions(options, isRoot: true));
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
          for (final rawOutput in rawAllowedOutputs)
            AssetId.parse(rawOutput as String),
        ],
        inputTracker: inputTracker,
        buildFilesystem: runtime.buildFilesystem,
        phase: _phaseOf(message),
        resolvers: resolver,
        resourceManager: runtime.resourceManager,
      );
      try {
        await builder.build(step);
      } finally {
        await step.complete();
      }
    }
    profile.runBuilderUs = runBuilderTimer.elapsedMicroseconds;

    final resolverReadsTimer = Stopwatch()..start();
    await collectResolverReads(runtime.io, runtime.packageConfig);
    profile.resolverReadsUs = resolverReadsTimer.elapsedMicroseconds;

    final resultAssemblyTimer = Stopwatch()..start();
    final outputEntries = isPostProcess
        ? runtime.io.outputs.entries
        : step!.outputs.entries.map(
            (entry) => MapEntry(entry.key, entry.value.bytes),
          );
    final outputs = <Map<String, dynamic>>[
      for (final entry in outputEntries)
        <String, dynamic>{'asset': entry.key.toString(), 'bytes': entry.value},
    ];
    final reads = <String>{
      input.toString(),
      if (step != null) ...step.inputTracker.inputs.map((id) => id.toString()),
      ...runtime.io.observedReads.map((id) => id.toString()),
      ...runtime.io.observedGlobResults.map((id) => id.toString()),
    }.toList()..sort();
    final resolverReads = <String>{
      if (step != null)
        ...step.inputTracker.resolverEntrypoints.map((id) => id.toString()),
      ...runtime.io.observedReads.map((id) => id.toString()),
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
    profile.status = 'success';
    return <String, dynamic>{
      'v': 1,
      'type': 'build_result',
      'id': message['id'],
      'status': 'success',
      'outputs': outputs,
      'deleted': <String>[for (final asset in deleted) asset.toString()]
        ..sort(),
      'reads': reads,
      'resolver_reads': resolverReads,
      'glob_reads': <Map<String, String>>[
        for (final glob in globReads)
          <String, String>{'package': glob.package, 'pattern': glob.pattern},
      ],
      'diagnostics': <dynamic>[],
    };
  } finally {
    profile.emit();
  }
}

String _instanceKey(JsonMap message) {
  final explicit = message['instance_key'];
  if (explicit is String && explicit.isNotEmpty) return explicit;
  return '${message['kind']}|${message['builder']}|${jsonEncode(message['options'] ?? const {})}';
}

int _phaseOf(JsonMap message) {
  final value = message['phase'];
  return value is num ? value.toInt() : 0;
}
