import 'dart:convert';

import 'package:build/build.dart';
import 'package:build_runner/src/build/asset_content.dart' show AssetContent;
import 'package:build_runner/src/build/build_step_impl.dart' show BuildStepImpl;
import 'package:build_runner/src/build/builder_filesystem.dart'
    show BuilderFilesystem;
import 'package:build_runner/src/build/input_tracker.dart' show InputTracker;
import 'package:build_runner/src/build_plan/build_inputs.dart' show BuildInputs;
import 'package:build_runner/src/build_plan/build_packages.dart'
    show BuildPackages;
import 'package:glob/glob.dart';
import 'package:package_config/package_config.dart';

import 'api_fingerprint.dart' show LearnedApiFingerprint;
import 'asset_read_cache.dart';
import 'blake3.dart';
import 'current_build_runtime.dart';
import 'protocol.dart';
import 'remote_build_step.dart';
import 'resolver_host.dart';
import 'resolver_reads.dart';
import 'worker_reset.dart';
import 'worker_resolvers.dart' show WorkerResolversImpl;

typedef SharedPartEncoder = Future<JsonMap> Function(BuildStepImpl, String);
typedef SharedPartStepFactory =
    BuildStepImpl Function(
      AssetId,
      Iterable<AssetId>,
      InputTracker,
      BuilderFilesystem,
      int,
      int,
      Resolvers,
      ResourceManager,
    );

class WorkerTransportState {
  // Last accepted batch visibility hint, scoped to this worker context.
  // Resolver/build resets and nested single builds leave transport state
  // intact. The raw list and its parsed set live in one record so they can
  // never be updated separately and drift apart.
  ({List<String> assets, Set<AssetId> ids})? _batchBlocked;

  List<String>? get batchBlockedAssets => _batchBlocked?.assets;

  // Asset-id dictionary for `asset-id-interning-v1`, scoped to this worker
  // context with the same lifetime as the batch visibility hint above.
  // Initialization clears it; interned messages append to it in place.
  final List<String> assetDictionary = <String>[];

  // Frontend source digests for `asset-digests-v1` (ADR 0054), keyed by
  // asset id string, with the same lifetime as the asset dictionary.
  // Batch messages apply their deltas to it in place, so per-build
  // holders of this map (the builder filesystem) see updates directly.
  final Map<String, String> assetDigests = <String, String>{};

  void resetOnInitialize() {
    _batchBlocked = null;
    assetDictionary.clear();
    assetDigests.clear();
  }

  void applyAssetDigestUpdates(Map<String, String?> updates) {
    for (final entry in updates.entries) {
      final digest = entry.value;
      if (digest == null) {
        assetDigests.remove(entry.key);
      } else {
        assetDigests[entry.key] = digest;
      }
    }
  }

  Set<AssetId> resolveBatchBlockedAssets(List<String> blockedAssets) {
    final current = _batchBlocked;
    if (current != null && identical(current.assets, blockedAssets)) {
      return current.ids;
    }
    final parsed = Set<AssetId>.unmodifiable(blockedAssets.map(AssetId.parse));
    _batchBlocked = (assets: blockedAssets, ids: parsed);
    return parsed;
  }
}

class WorkerRuntime {
  WorkerRuntime(
    this.packageConfig,
    this.resolverProfile, {
    this.sharedPartEncoder,
    this.sharedPartStepFactory,
  }) : resolver = createResolver(packageConfig, resolverProfile);

  final WorkerTransportState transport = WorkerTransportState();
  final WorkerResetState resetState = WorkerResetState();

  final PackageConfig packageConfig;
  final ResolverInitializationProfile resolverProfile;
  final SharedPartEncoder? sharedPartEncoder;
  final SharedPartStepFactory? sharedPartStepFactory;

  bool get supportsSharedParts =>
      sharedPartEncoder != null && sharedPartStepFactory != null;
  bool get buildStarted => _buildStarted;
  int get phaseCount => _phaseCount;

  WorkerResolversImpl resolver;
  final ResourceManager resourceManager = ResourceManager();
  final readCache = AssetReadCache();
  final Set<AssetId> readableCache = <AssetId>{};
  final ResolverDependencyCache resolverDependencyCache =
      ResolverDependencyCache();

  /// Bytes of outputs this worker produced during the current build.
  ///
  /// Source outputs stay in the Rust overlay until the final commit, so they
  /// cannot be re-read from disk after a phase commit; the worker already
  /// holds their bytes from the build results it returned.
  final Map<AssetId, AssetContent> producedOutputs = <AssetId, AssetContent>{};

  /// Dep-graph values already transmitted to Rust, keyed by asset. Entries
  /// are re-sent only when a reset rebuilt them, identified by instance
  /// rather than content.
  final Map<AssetId, Object> sentDepGraphValues = <AssetId, Object>{};

  /// API fingerprints already transmitted to Rust, keyed by asset id
  /// string (ADR 0056).
  final Map<String, LearnedApiFingerprint> sentApiFingerprints =
      <String, LearnedApiFingerprint>{};

  /// Resolver entrypoints recorded by every build action of the current
  /// batch, including nested builds whose results do not join `results`.
  final Set<AssetId> batchResolverEntrypoints = <AssetId>{};

  final Map<String, Builder> builders = <String, Builder>{};
  final Map<String, PostProcessBuilder> postProcessBuilders =
      <String, PostProcessBuilder>{};

  String? currentPackage;
  Map<String, List<Glob>> inputRestrictions = const {};
  late RemoteAssetReaderWriter io;
  late BuildPackages buildPackages;
  late RemoteBuildState buildState;
  late RemoteBuilderFilesystem buildFilesystem;
  bool _buildStarted = false;
  bool retainedOutputGuard = false;
  bool resolverInitialized = false;
  int _phaseCount = 1;

  /// Highest phase at which the dep-load queue was drained. Assets that
  /// expired before a phase are re-loaded by the next library load at any
  /// later phase, regardless of which closure they belong to; running that
  /// drain between actions keeps the reload reads unattributed.
  int _lastDepDrainPhase = -1;

  /// Starts a new build series for [package].
  Future<void> startBuild(
    String package, {
    required int phaseCount,
    required Map<String, List<String>> inputRestrictions,
  }) async {
    if (_buildStarted) {
      await resourceManager.disposeAll();
      _replaceResolver();
      _buildStarted = false;
    }
    currentPackage = package;
    this.inputRestrictions = {
      for (final entry in inputRestrictions.entries)
        entry.key: [for (final pattern in entry.value) Glob(pattern)],
    };
    _phaseCount = phaseCount < 1 ? 1 : phaseCount;
    _clearPerBuildState();
    await _startBuild();
  }

  /// Answers an ADR 0056 preflight query: for each unit, reads the
  /// current content through the asset RPC (bypassing per-build
  /// content state, so watch residents answer for the bytes on disk
  /// now), verifies it against the frontend's snapshot digest, and
  /// computes the unit's API fingerprint and direct resolver deps from
  /// that content. Any failure leaves the entry's values null, which
  /// the frontend treats as no evidence.
  Future<Map<String, Object?>> apiFingerprintQuery(
    List<ApiFingerprintQueryEntry> entries,
  ) async {
    // The query's reads (and the dep loads its parses trigger) go
    // through the shared read caches, and this worker goes on to
    // execute the build. Content read here can be newer than the
    // frontend's snapshot: a file edited after the snapshot and
    // restored before the action runs would otherwise leave the
    // temporary bytes cached, and execution would consume content
    // the snapshot never contained while the committed snapshot
    // still matches disk. Restore both caches afterwards so the
    // query leaves no content behind.
    final savedReadCache = Map<AssetId, List<int>>.of(readCache);
    final savedReadableCache = Set<AssetId>.of(readableCache);
    // The query is itself the API-cutoff operation: the frontend sends
    // it only for opted-in builds, and the dep walks it triggers must
    // learn the fingerprints it answers with. Learning is otherwise
    // gated to opted-in build actions (ADR 0056), which have not run
    // yet when a preflight query arrives, so enable it for the query
    // and restore the caller's setting afterwards.
    final previousLearning = resolver.fingerprintLearningEnabled;
    resolver.setFingerprintLearningEnabled(true);
    try {
      return await _apiFingerprintQuery(entries);
    } finally {
      resolver.setFingerprintLearningEnabled(previousLearning);
      readCache.removeWhere((id, _) => !savedReadCache.containsKey(id));
      savedReadCache.forEach((id, bytes) {
        if (!identical(readCache[id], bytes)) {
          readCache[id] = bytes;
        }
      });
      readableCache
        ..removeWhere((id) => !savedReadableCache.contains(id))
        ..addAll(savedReadableCache);
    }
  }

  Future<Map<String, Object?>> _apiFingerprintQuery(
    List<ApiFingerprintQueryEntry> entries,
  ) async {
    final results = <String, Object?>{};
    for (final entry in entries) {
      String? fingerprint;
      List<String>? deps;
      if (_buildStarted) {
        try {
          final id = AssetId.parse(entry.asset);
          final bytes = await buildFilesystem.readerWriter.readAsBytes(id);
          final content = utf8.decode(bytes);
          // Snapshot digests are algorithm-tagged (`b3-<hex>`); the
          // fingerprint cache keys on the bare hex.
          final expectedDigest = entry.digest.startsWith('b3-')
              ? entry.digest.substring(3)
              : entry.digest;
          if (blake3Hex(bytes) == expectedDigest) {
            deps = resolver
                .preflightUnitDeps(
                  id,
                  content,
                  builderFilesystem: buildFilesystem,
                  phase: _phaseCount,
                )
                .map((dep) => dep.toString())
                .toList();
            // The learned record is usable only when it was learned
            // from exactly these bytes: a file whose decoded content
            // hashes differently than its raw bytes (a leading BOM,
            // which utf8.decode drops) learns a record bound to the
            // re-encoded digest, and returning its fingerprint here
            // would bind it to the snapshot digest it does not
            // describe. Such units stay content-keyed (ADR 0056).
            final learned = resolver.learnedApiFingerprints()[entry.asset];
            if (learned != null && learned.digest == expectedDigest) {
              fingerprint = learned.fingerprint;
            }
          }
        } catch (_) {
          // Unreadable or undecodable content is simply unavailable.
        }
      }
      results[entry.asset] = <String, Object?>{
        'fingerprint': fingerprint,
        'deps': deps,
      };
    }
    return results;
  }

  /// Ends the previous build and starts the next one with a fresh build
  /// filesystem while retaining Resource identity and reusable read caches only
  /// where current worker semantics allow it.
  Future<void> reset() async {
    if (!_buildStarted) return;
    await resourceManager.disposeAll();
    _replaceResolver();
    _buildStarted = false;
    resetState.clearOverlayExtractions();
    _clearPerBuildState();
    await _startBuild();
  }

  /// Reopens the current resolver's analysis model after Rust commits a
  /// source-output phase. A new BuilderFilesystem is required because current
  /// build_runner allows a filesystem to register its content listener once.
  ///
  /// With [incremental], the analyzer's in-memory filesystem and the loaded
  /// library-cycle graph are kept: only [updatedSources] are refreshed and
  /// [deletedSources] evicted, so unchanged sources do not get re-analyzed.
  /// Cache-tree changes are supplied separately and refresh the same caches;
  /// generated Dart files there stay Analyzer-visible like source outputs.
  Future<void> resetResolver({
    Set<AssetId> updatedSources = const <AssetId>{},
    Set<AssetId> deletedSources = const <AssetId>{},
    Set<AssetId> updatedCache = const <AssetId>{},
    Set<AssetId> deletedCache = const <AssetId>{},
    bool incremental = false,
    Map<String, Object?>? overlayBlob,
  }) => runResetResolver(
    runtime: this,
    updatedSources: updatedSources,
    deletedSources: deletedSources,
    updatedCache: updatedCache,
    deletedCache: deletedCache,
    incremental: incremental,
    overlayBlob: overlayBlob,
  );

  Future<void> restartCleanAfterReset() async {
    _replaceResolver();
    _buildStarted = false;
    await _startBuild(clearReadCaches: false, clearBuilders: false);
    resetState.clearOverlayExtractions();
  }

  Future<void> restartIncrementalAfterReset(BuildInputs buildInputs) async {
    _buildStarted = false;
    await _startBuild(
      buildInputs: buildInputs,
      clearReadCaches: false,
      clearBuilders: false,
    );
  }

  Future<({Set<AssetId> reads, Set<AssetId> resolverReads})>
  drainPendingDepLoadsForPhase(int phase) async {
    if (phase <= _lastDepDrainPhase) {
      return (reads: const <AssetId>{}, resolverReads: const <AssetId>{});
    }
    _lastDepDrainPhase = phase;
    // Expired dep entries are re-loaded eagerly by the next library load
    // regardless of which closure they belong to. Completing those queued
    // loads first keeps the bookkeeping reads attributable so they can be
    // excluded from this action's recorded reads; the completed deps still
    // reach the exported dep graph.
    final readsBeforeDrain = Set<AssetId>.of(io.observedReads);
    final resolverReadsBeforeDrain = Set<AssetId>.of(io.resolverObservedReads);
    await resolver.drainPendingDepLoads(
      builderFilesystem: buildFilesystem,
      phase: phase,
    );
    return (
      reads: io.observedReads.difference(readsBeforeDrain),
      resolverReads: io.resolverObservedReads.difference(
        resolverReadsBeforeDrain,
      ),
    );
  }

  /// Direct dependency edges the resolver loader has recorded so far.
  ///
  /// Actions that resolve an already-loaded library cycle observe no new IO,
  /// so their dependency edges cannot be recovered from reads alone. The
  /// Rust graph expands resolver entrypoints through this map at dirty-check
  /// time, the same way stock build_runner expands them via
  /// `previousLibraryCycleGraphLoader`. Only the subgraph reachable from
  /// [entrypoints] is serialized: entries for assets this batch never resolved
  /// cannot affect the dirty checks that follow from these entrypoints.
  Map<String, List<String>> encodeDepGraphDelta(Set<AssetId> entrypoints) {
    final deps = resolver.phasedAssetDeps();
    final result = <String, List<String>>{};
    final visited = <AssetId>{};
    final pending = entrypoints.toList();
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!visited.add(id)) continue;
      final values = deps.assetDeps[id]?.values;
      if (values == null || values.isEmpty) continue;
      final assetDeps = values.last.value.deps;
      // Empty dep lists are serialized too: the Rust merge replaces edges per
      // key, and skipping the record would leave stale edges behind.
      // An entry already sent with the same recorded value does not need
      // another copy; a rebuilt graph produces fresh value objects.
      if (identical(sentDepGraphValues[id], values.last)) {
        pending.addAll(assetDeps);
        continue;
      }
      sentDepGraphValues[id] = values.last;
      result[id.toString()] = <String>[
        for (final dep in assetDeps) dep.toString(),
      ];
      pending.addAll(assetDeps);
    }
    return result;
  }

  /// API fingerprints the dep walk learned that Rust has not been sent
  /// yet (ADR 0056): the delta of learned fingerprints against
  /// [sentApiFingerprints], which is updated in place. Each value binds the
  /// fingerprint to the digest of the content that produced it; units whose
  /// fingerprint is unavailable are sent as null so the frontend drops any
  /// fingerprint it recorded for an earlier content of the same asset.
  Map<String, Object?> encodeApiFingerprintsDelta() {
    final learned = resolver.learnedApiFingerprints();
    final result = <String, Object?>{};
    for (final entry in learned.entries) {
      if (sentApiFingerprints.containsKey(entry.key) &&
          sentApiFingerprints[entry.key] == entry.value) {
        continue;
      }
      sentApiFingerprints[entry.key] = entry.value;
      final fingerprint = entry.value.fingerprint;
      result[entry.key] = fingerprint == null
          ? null
          : <String, String>{
              'digest': entry.value.digest,
              'fingerprint': fingerprint,
            };
    }
    return result;
  }

  Future<void> close() async {
    if (_buildStarted) {
      await resourceManager.disposeAll();
      resolver.reset();
      _buildStarted = false;
    }
    await resourceManager.beforeExit();
  }

  void _replaceResolver() {
    if (resolverProfile.enabled) resolverProfile.resolverReplacements++;
    resolver.reset();
    resolver = createResolver(packageConfig, resolverProfile);
  }

  void _clearPerBuildState() {
    readCache.clear();
    readableCache.clear();
    resolverDependencyCache.clear();
    producedOutputs.clear();
    resetState.clearForNewBuild();
    sentDepGraphValues.clear();
    sentApiFingerprints.clear();
    // Learned fingerprints are keyed by asset, not by content, so an
    // observation from an earlier build could overwrite a fresher one
    // another worker reported in the meantime. Only this build's own
    // observations may be reported.
    resolver.clearLearnedApiFingerprints();
    batchResolverEntrypoints.clear();
    builders.clear();
    postProcessBuilders.clear();
    _lastDepDrainPhase = -1;
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
      inputRestrictions: inputRestrictions,
      assetDigests: transport.assetDigests,
    );
    await resolver.takeLockAndStartBuild(
      builderFilesystem: buildFilesystem,
      buildInputs: buildInputs ?? cleanBuildInputs(),
    );
    _buildStarted = true;
  }
}
