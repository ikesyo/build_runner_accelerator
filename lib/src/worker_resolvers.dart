// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/file_system/file_system.dart' show ResourceProvider;
// ignore: implementation_imports
import 'package:analyzer/src/clients/build_resolvers/build_resolvers.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/byte_store.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_content_cache.dart';
import 'package:build/build.dart';
import 'package:build/experiments.dart';
import 'package:package_config/package_config.dart' hide Package;
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';
import 'package:pub_semver/pub_semver.dart';

import 'analysis_startup_gate.dart';
import 'cache_directory.dart';
import 'analysis_byte_store_fingerprint.dart';
import 'packed_analysis_byte_store.dart';

// ignore: implementation_imports
import 'package:build_runner/src/bootstrap/build_process_state.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build_plan/build_inputs.dart';
// ignore: implementation_imports
import 'package:build_runner/src/logging/build_log.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/build_step_impl.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/builder_filesystem.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/phased_asset_deps.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/analysis_driver.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/analysis_driver_filesystem.dart';
import 'resolver_host.dart' show ResolverInitializationProfile;
import 'resolver_metrics.dart';
import 'sdk_summary_lock.dart';
import 'worker_analysis_driver_model.dart';
import 'worker_analysis_options.dart';
import 'worker_step_resolver.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/build_resolver.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/build_step_resolver.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/sdk_summary.dart'
    show isFlutter;

/// The [Resolvers] used in the build.
///
/// Forked from build_runner's `ResolversImpl` to use
/// [WorkerAnalysisDriverModel], which can keep the library-cycle graph across
/// an in-build resolver reset.
///
/// Factory for [BuildStepResolver] instances that provide analysis for one
/// build step. These provide access to a single underlying [BuildResolver]
/// which has one analysis driver and manages it via one [AnalysisDriverModel].
class WorkerResolversImpl implements Resolvers {
  /// Guards initialization of this class.
  final _initializationPool = Pool(1);

  /// Guards access to the analysis driver.
  final _driverPool = Pool(1);

  /// The main build resolver backed by an analysis driver.
  BuildResolver? _buildResolver;
  AnalysisStartupGate? _startupGate;

  /// State supporting the analysis driver.
  WorkerAnalysisDriverModel _analysisDriverModel;

  /// Specifies the language version for each package during analysis.
  PackageConfig? _packageConfig;

  /// Optional diagnostics sink for the lazy resolver initialization path.
  final ResolverInitializationProfile? _profile;

  /// Creates a new resolvers instance.
  ///
  /// Specify [packageConfig] to override package language versions for
  /// analysis. Otherwise, it will be created from
  /// `buildProcessState.packageConfigUri`.
  ///
  /// A new [AnalysisDriverModel] will be created, or pass one as
  /// [analysisDriverModel].
  factory WorkerResolversImpl.custom({
    PackageConfig? packageConfig,
    WorkerAnalysisDriverModel? analysisDriverModel,
    ResolverInitializationProfile? profile,
  }) => WorkerResolversImpl(
    packageConfig: packageConfig,
    analysisDriverModel: analysisDriverModel ?? WorkerAnalysisDriverModel(),
    profile: profile,
  );

  WorkerResolversImpl({
    PackageConfig? packageConfig,
    required WorkerAnalysisDriverModel analysisDriverModel,
    ResolverInitializationProfile? profile,
  }) : _packageConfig = packageConfig,
       _analysisDriverModel = analysisDriverModel,
       _profile = profile;

  @override
  Future<ReleasableResolver> get(BuildStep buildStep) async {
    await _initializationPool.withResource(() async {
      if (_buildResolver != null) return;
      _warnOnLanguageVersionMismatch();
      final loadedConfig = _packageConfig ??= await loadPackageConfigUri(
        Uri.parse(buildProcessState.packageConfigUri),
      );
      // Concurrent worker processes take the same `.sdk-summary.lock` the
      // prewarm shards hold, so a cold workspace builds `sdk.sum` once
      // instead of once per worker.
      final sdkSummaryStopwatch = _profile?.enabled == true
          ? (Stopwatch()..start())
          : null;
      final sdkSummary = await sharedSdkSummaryPath();
      if (sdkSummaryStopwatch != null) {
        _profile?.sdkSummaryUs = sdkSummaryStopwatch.elapsedMicroseconds;
        _profile?.sdkSummaryLockWaitUs = sdkSummary.lockWaitUs;
        _profile?.sdkSummaryAfterLockUs = sdkSummary.generatorUs;
      }
      final sdkSummaryReadTimer = _profile?.enabled == true
          ? (Stopwatch()..start())
          : null;
      final sdkSummaryBytes = await File(sdkSummary.path).readAsBytes();
      if (sdkSummaryReadTimer != null) {
        _profile?.sdkSummaryReadUs = sdkSummaryReadTimer.elapsedMicroseconds;
      }
      final driverCreateTimer = _profile?.enabled == true
          ? (Stopwatch()..start())
          : null;
      final byteStore = sharedAnalysisByteStore(sdkSummaryBytes, loadedConfig);
      _startupGate = _sharedStartupGates[byteStore];
      final driver = _analysisDriver(
        _analysisDriverModel,
        workerAnalysisOptions(
          _featureSet(enableExperiments: enabledExperiments),
        ),
        sdkSummaryBytes,
        loadedConfig,
        byteStore,
      );
      if (driverCreateTimer != null) {
        _profile?.driverCreateUs = driverCreateTimer.elapsedMicroseconds;
      }

      final buildResolverTimer = _profile?.enabled == true
          ? (Stopwatch()..start())
          : null;
      _buildResolver = BuildResolver(driver, _driverPool, _analysisDriverModel);
      if (_profile?.enabled == true) _profile!.driverCreations++;
      if (buildResolverTimer != null) {
        _profile?.buildResolverCtorUs = buildResolverTimer.elapsedMicroseconds;
      }
    });

    final stepResolver = BuildStepResolver(
      _buildResolver!,
      buildStep as BuildStepImpl,
    );
    if (_profile?.enabled == true || _startupGate?.isReady == false) {
      return WorkerStepResolver(
        stepResolver,
        startupGate: _startupGate,
        timingEnabled: _profile?.enabled == true,
      );
    }
    return stepResolver;
  }

  /// Starts a build.
  ///
  /// If another build has the lock, waits for it to finish.
  ///
  /// The lock is released on [reset].
  ///
  /// TODO(davidmorgan): taking the lock is not enforced because `Resolvers` is
  /// a public API that does not support locking and `ResolversImpl` is private
  /// implementation that needs locking. Find a way to do better. Fortunately,
  /// only two codepaths need to care about the lock: the main build in
  /// `build.dart` and test builds in `package:build_test` `test_builder.dart`.
  Future<void> takeLockAndStartBuild({
    required BuilderFilesystem builderFilesystem,
    required BuildInputs buildInputs,
  }) => _analysisDriverModel.takeLockAndStartBuild(
    builderFilesystem: builderFilesystem,
    buildInputs: buildInputs,
  );

  PhasedAssetDeps phasedAssetDeps() => _analysisDriverModel.phasedAssetDeps();

  /// Completes dep loads queued for [phase] or earlier while no action owns
  /// the reader; see [WorkerAnalysisDriverModel.drainPendingDepLoads].
  Future<void> drainPendingDepLoads({
    required BuilderFilesystem builderFilesystem,
    required int phase,
  }) => _analysisDriverModel.drainPendingDepLoads(
    builderFilesystem: builderFilesystem,
    phase: phase,
  );

  /// Frees the lock taken by [takeLockAndStartBuild].
  ///
  /// Or if none was taken, does nothing.
  ///
  /// With [clearGraph] false the library-cycle graph is kept for reuse by the
  /// next build started under this resolver.
  void reset({bool clearGraph = true}) {
    _analysisDriverModel.endBuildAndUnlock(clearGraph: clearGraph);
  }
}

/// Builds an [AnalysisDriverForPackageBuild] backed by a summary SDK and a
/// shared on-disk byte store.
///
/// Forked from build_runner's `analysisDriver` to pass [byteStore]; it must
/// stay in sync with `package:build_runner/src/build/resolver/analysis_driver.dart`.
AnalysisDriverForPackageBuild _analysisDriver(
  WorkerAnalysisDriverModel analysisDriverModel,
  AnalysisOptions analysisOptions,
  Uint8List sdkSummaryBytes,
  PackageConfig packageConfig,
  ByteStore byteStore,
) {
  return createAnalysisDriver(
    analysisOptions: analysisOptions,
    packages: _buildAnalyzerPackages(
      packageConfig,
      analysisDriverModel.filesystem,
    ),
    resourceProvider: analysisDriverModel.filesystem,
    fileContentCache: resolverActionMetrics.enabled
        ? _MetricsFileContentCache(analysisDriverModel.filesystem)
        : analysisDriverModel.filesystem,
    sdkSummaryBytes: sdkSummaryBytes,
    uriResolvers: [analysisDriverModel.filesystem],
    byteStore: byteStore,
  );
}

/// Mirrors build_runner's private `_buildAnalyzerPackages`; see
/// `package:build_runner/src/build/resolver/analysis_driver.dart`.
Packages _buildAnalyzerPackages(
  PackageConfig packageConfig,
  ResourceProvider resourceProvider,
) => Packages({
  for (final package in packageConfig.packages)
    package.name: Package(
      name: package.name,
      languageVersion: package.languageVersion == null
          ? sdkLanguageVersion
          : Version(
              package.languageVersion!.major,
              package.languageVersion!.minor,
              0,
            ),
      // Analyzer does not see the original file paths at all, we need to
      // make them match the paths that we give it, so we use the
      // `assetPath` function to create those.
      rootFolder: resourceProvider.getFolder(
        p.url.normalize(
          AnalysisDriverFilesystem.assetPathFor(
            package: package.name,
            path: '',
          ),
        ),
      ),
      libFolder: resourceProvider.getFolder(
        p.url.normalize(
          AnalysisDriverFilesystem.assetPathFor(
            package: package.name,
            path: 'lib',
          ),
        ),
      ),
    ),
});

/// Upper bound of the in-memory layer in front of the on-disk store.
const _memoryCacheBytes = 128 * 1024 * 1024;

/// Environment variable that disables the shared on-disk byte store when set
/// to `0`, `false`, or `off`.
const _byteStoreEnv = 'BUILD_RUNNER_ACCELERATOR_BYTE_STORE';

/// Environment variable that restores per-key file layouts in the on-disk
/// caches (the analyzer byte store and the dep-parse cache) when set to `0`.
const _packedStoreEnv = 'BUILD_RUNNER_ACCELERATOR_PACKED_STORE';

/// Byte-store instances per fingerprint for this process. Phase resets
/// rebuild the analysis driver; keeping the [MemoryCachingByteStore] layer
/// alive across those rebuilds means a later phase does not re-pay the disk
/// store look-ups the earlier phase already warmed. Keys are content- and
/// version-addressed, so entries stay valid and missed keys are simply
/// recomputed — the memory layer never caches nulls.
final _sharedByteStores = <String, ByteStore>{};
final _sharedStartupGates = <ByteStore, AnalysisStartupGate>{};

/// A [ByteStore] shared between workers and across builds.
///
/// Analyzer byte-store keys are content- and version-addressed (salt,
/// feature set, language version, file content), so entries produced by other
/// workers or previous builds are reusable and stale keys are simply ignored.
/// Because the key does not include SDK or analyzer identity, the cache
/// directory is namespaced by a fingerprint of the SDK summary, the resolved
/// analyzer package, and the enabled experiments so that upgrading any of
/// them cannot reuse element models built against a different toolchain.
/// The store lives under the machine-wide accelerator cache so fresh
/// checkouts and sibling workspaces reuse it instead of rebuilding per
/// workspace.
ByteStore sharedAnalysisByteStore(
  Uint8List sdkSummaryBytes,
  PackageConfig packageConfig,
) {
  final disabled = switch ((Platform.environment[_byteStoreEnv] ?? '')
      .toLowerCase()) {
    '0' || 'false' || 'off' => true,
    _ => false,
  };
  if (disabled) return MemoryByteStore();

  final fingerprint = analysisByteStoreFingerprint(
    sdkSummaryBytes,
    experiments: enabledExperiments,
    analyzerRoot: packageConfig['analyzer']?.root.toString() ?? '',
  );
  final dir = p.joinAll([
    acceleratorCacheDirectory(),
    'byte_store',
    Platform.environment[_packedStoreEnv] != '0' ? 'v2' : 'per-key-v1',
    fingerprint,
  ]);
  // Neither on-disk store creates the directory itself; without it the writes
  // fail silently.
  return _sharedByteStores.putIfAbsent(fingerprint, () {
    try {
      Directory(dir).createSync(recursive: true);
    } on FileSystemException {
      return MemoryByteStore();
    }
    final disk = Platform.environment[_packedStoreEnv] == '0'
        ? FileByteStore(dir) as ByteStore
        : PackedAnalysisByteStore(dir);
    final store = MemoryCachingByteStore(disk, _memoryCacheBytes);
    final result = resolverActionMetrics.enabled
        ? _MetricsByteStore(store)
        : store;
    if (Platform
            .environment['BUILD_RUNNER_ACCELERATOR_ANALYSIS_SINGLE_FLIGHT'] ==
        '1') {
      _sharedStartupGates[result] = AnalysisStartupGate(
        p.join(dir, '.analysis-startup.lock'),
        isWarm: disk is PackedAnalysisByteStore
            ? () => disk.hasLinkedEntries
            : () => PackedAnalysisByteStore.hasPerKeyLinkedEntries(dir),
      );
    }
    return result;
  });
}

/// Counts hits, misses and time on the shared [ByteStore] for the resolver
/// startup breakdown, split by key suffix. Keys are content-addressed, so
/// counters are the only behavioral difference.
class _MetricsByteStore implements ByteStore {
  _MetricsByteStore(this._delegate);

  final ByteStore _delegate;

  @override
  Uint8List? get(String key) {
    final timer = Stopwatch()..start();
    final bytes = _delegate.get(key);
    final us = timer.elapsedMicroseconds;
    final metrics = resolverActionMetrics
      ..byteStoreGets += 1
      ..byteStoreGetUs += us;
    if (key.endsWith('.unlinked2')) {
      metrics
        ..byteStoreGetsUnlinked += 1
        ..byteStoreGetUnlinkedUs += us;
    } else if (key.endsWith('.linked')) {
      metrics
        ..byteStoreGetsLinked += 1
        ..byteStoreGetLinkedUs += us;
    } else {
      metrics
        ..byteStoreGetsOther += 1
        ..byteStoreGetOtherUs += us;
    }
    if (bytes != null) resolverActionMetrics.byteStoreHits++;
    if (bytes == null && resolverActionMetrics.traceEnabled) {
      resolverActionMetrics.byteStoreMissKeys.add(key);
    }
    return bytes;
  }

  @override
  Uint8List putGet(String key, Uint8List bytes) {
    final timer = Stopwatch()..start();
    final result = _delegate.putGet(key, bytes);
    resolverActionMetrics
      ..byteStorePuts += 1
      ..byteStorePutUs += timer.elapsedMicroseconds
      ..byteStorePutBytes += bytes.length;
    return result;
  }

  @override
  void release(Iterable<String> keys) => _delegate.release(keys);
}

/// Times `FileContentCache.get` — the `AnalysisDriverFilesystem._data` reads
/// that `FileState.refresh` performs inside `libraryFor`/`updateDriver`.
class _MetricsFileContentCache implements FileContentCache {
  _MetricsFileContentCache(this._delegate);

  final FileContentCache _delegate;

  @override
  FileContent get(String path) {
    if (resolverActionMetrics.traceEnabled) {
      resolverActionMetrics.fileContentPaths.add(path);
    }
    final timer = Stopwatch()..start();
    try {
      return _delegate.get(path);
    } finally {
      resolverActionMetrics
        ..fileContentGets += 1
        ..fileContentGetUs += timer.elapsedMicroseconds;
    }
  }

  @override
  void invalidate(String path) => _delegate.invalidate(path);

  @override
  void invalidateAll() => _delegate.invalidateAll();
}

/// Checks that the current analyzer version supports the current language
/// version.
void _warnOnLanguageVersionMismatch() async {
  if (sdkLanguageVersion <= ExperimentStatus.currentVersion) return;

  final upgradeCommand = isFlutter
      ? 'flutter packages upgrade'
      : 'dart pub upgrade';
  buildLog.warning(
    'SDK language version $sdkLanguageVersion is newer than `analyzer` '
    'language version ${ExperimentStatus.currentVersion}. '
    'Run `$upgradeCommand`.',
  );
}

/// The current feature set based on the current sdk version and enabled
/// experiments.
FeatureSet _featureSet({List<String> enableExperiments = const []}) {
  if (enableExperiments.isNotEmpty &&
      sdkLanguageVersion > ExperimentStatus.currentVersion) {
    buildLog.warning('''
Attempting to enable experiments `$enableExperiments`, but the current SDK
language version does not match your `analyzer` package language version:

Analyzer language version: ${ExperimentStatus.currentVersion}
SDK language version: $sdkLanguageVersion

In order to use experiments you may need to upgrade or downgrade your
`analyzer` package dependency such that its language version matches that of
your current SDK, see https://github.com/dart-lang/build/issues/2685.

Note that you may or may not have a direct dependency on the `analyzer`
package in your `pubspec.yaml`, so you may have to add that. You can see your
current version by running `pub deps`.
''');
  }
  return FeatureSet.fromEnableFlags2(
    sdkLanguageVersion: sdkLanguageVersion,
    flags: enableExperiments,
  );
}
