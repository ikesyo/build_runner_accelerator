import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:build/build.dart';
import 'package:build_runner/src/bootstrap/build_process_state.dart'
    show buildProcessState;
import 'package:build_runner/src/logging/build_log.dart' show buildLog;
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';

import 'compiler_package_config.dart';
import 'frontend_binary_resolver.dart' show buildRunnerAcceleratorVersion;
import 'manifest/trigger_worker.dart' show writeManifestTriggers;
import 'protocol.dart';
import 'resolver_host.dart' show ResolverInitializationProfile;
import 'worker_action_runner.dart';
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
  final actionRunner = WorkerActionRunner(
    reader: reader,
    writer: writer,
    runtime: runtime,
    builderCatalog: catalog,
    postProcessCatalog: postProcessCatalog,
  );
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
              onControlMessage: actionRunner.handleNestedBuild,
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
            await actionRunner.handleBuild(build.request);
          case WorkerBuildBatchMessage buildBatch:
            runtime.transport.applyAssetDigestUpdates(
              buildBatch.assetDigestUpdates,
            );
            await actionRunner.handleBuildBatch(buildBatch);
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
