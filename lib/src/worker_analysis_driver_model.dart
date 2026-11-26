import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
// ignore: implementation_imports
import 'package:analyzer/src/clients/build_resolvers/build_resolvers.dart';
import 'package:build/build.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/build_step_impl.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/builder_filesystem.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/asset_deps.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/asset_deps_loader.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/library_cycle_graph_loader.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/phased_asset_deps.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/phased_value.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_content_cache.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/analysis_driver_filesystem.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/analysis_driver_model.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build_plan/build_inputs.dart';
// ignore: implementation_imports
import 'package:build_runner/src/logging/timed_activities.dart';
import 'package:pool/pool.dart';

import 'api_fingerprint.dart';
import 'asset_deps_cache.dart';
import 'blake3.dart';
import 'current_build_runtime.dart';
import 'resolver_metrics.dart';

/// Per-instance ledger of API fingerprints learned during dependency walks
/// (ADR 0056), owned by a [WorkerAnalysisDriverModel].
///
/// Keeping the learned map, content/digest memos, and learning flag on an
/// instance rather than on static fields ensures that replacing a resolver or
/// driver model starts with a clean ledger and cannot leak state across
/// instances.
class ApiFingerprintLedger {
  /// Unit fingerprints learned by dep walks on this ledger, keyed by
  /// asset id string (ADR 0056); a null fingerprint marks a unit whose
  /// fingerprint is unavailable. Reported to the frontend with the
  /// build results, delta-encoded against what it already has, like
  /// the dep graph.
  final Map<String, LearnedApiFingerprint> learned =
      <String, LearnedApiFingerprint>{};

  /// The exact content instance each asset's learned fingerprint was
  /// computed from, and the content digest recorded alongside it.
  /// Dep walks revisit the same units for every action whose
  /// resolver closure contains them, so relearning on every visit
  /// (a full-content hash plus a store lookup) multiplied the walk's
  /// cost by the action count; these memos reduce repeat visits of
  /// unchanged content to a map probe. Both are cleared with the
  /// learned map at each build boundary (see [clear]), so a
  /// resident worker does not retain the sources of deleted or
  /// renamed files for its whole lifetime.
  final Map<String, String> _learnedContents = <String, String>{};
  final Map<String, String> _learnedDigests = <String, String>{};

  /// Whether dep walks using this ledger record API fingerprints.
  /// Learning is off unless the action being executed opted in to
  /// the API cutoff (ADR 0056): the per-unit hash and store lookup
  /// otherwise tax every build for an opt-in feature, and on large
  /// closures that cost is the walk's dominant term. Set from the
  /// build request at each action's start; actions on one worker
  /// run sequentially, so the flag always matches the action whose
  /// walk is running.
  bool learningEnabled = false;

  /// Forgets what this ledger learned about [ids], whose bytes a
  /// resolver reset updated or deleted: the learning memos and the
  /// learned value itself are cleared, so the stale fingerprint is
  /// neither served from the memo nor re-reported with the next
  /// result. A later walk that loads the unit relearns its
  /// fingerprint from the new bytes. The frontend drops the
  /// recorded fingerprints for the same assets before dispatching
  /// post-reset actions.
  void invalidate(Iterable<AssetId> ids) {
    for (final id in ids) {
      final key = id.toString();
      _learnedContents.remove(key);
      _learnedDigests.remove(key);
      learned.remove(key);
    }
  }

  /// Clears [learned] and the learning memos. Called at each build
  /// start: only the new build's own observations may be reported,
  /// and the memos must not outlive that boundary.
  void clear() {
    learned.clear();
    _learnedContents.clear();
    _learnedDigests.clear();
  }

  /// Records the API fingerprint of the unit [id] with source
  /// [content] as learned. [parsed] reuses the dep walk's own parse
  /// when it has one; without it the fingerprint [cache] answers, and
  /// parses on a miss. A unit whose learned fingerprint is still in
  /// [learned] for the same content is not relearned: the worker
  /// clears this ledger at each build start, so a cleared entry is
  /// relearned (and re-reported) once per build, never once per walk
  /// visit.
  void record(
    AssetId id,
    String content, {
    required ApiFingerprintCache cache,
    ParseStringResult? parsed,
    String? frontendDigest,
  }) {
    final key = id.toString();
    // The AST-model gate can close mid-process (a misbehaving walk
    // latches it shut), after which every fingerprint is
    // unavailable. A memo hit must not serve a value learned before
    // the gate closed: report the unavailable marker so the
    // frontend drops the fingerprint it recorded earlier.
    if (!cache.modelSupported) {
      if (identical(_learnedContents[key], content) &&
          learned[key]?.fingerprint == null) {
        return;
      }
      final digest = blake3Hex(utf8.encode(content));
      _learnedContents[key] = content;
      _learnedDigests[key] = digest;
      learned[key] = (digest: digest, fingerprint: null);
      return;
    }
    if (identical(_learnedContents[key], content) && learned.containsKey(key)) {
      return;
    }
    // With a frontend-supplied digest (`asset-digests-v1`, ADR 0054)
    // the persistent cache answers by digest alone: the digest is
    // the BLAKE3 of the snapshot bytes the walk just read, so a hit
    // needs neither the content hash nor a parse. The memos are
    // cleared at each build boundary, so without this path the first
    // visit of every build rehashes the full content of every unit
    // in the closure. A miss falls through to learning from content;
    // the entry it stores is keyed by that same digest.
    if (frontendDigest != null) {
      // The digest memo may only answer for the very bytes it was
      // learned from: when preflight initialized this worker, an
      // edit landing before the action's walk can hand the walk
      // newer content under the same snapshot digest, and accepting
      // the memo would report the earlier fingerprint as evidence
      // about bytes it was never computed from.
      if (_learnedDigests[key] == frontendDigest &&
          learned.containsKey(key) &&
          _learnedContents[key] == content) {
        return;
      }
      if (cache.contains(frontendDigest, package: id.package)) {
        // Bind the cached fingerprint only to bytes that hash to the
        // frontend digest: a phased read can serve content newer than
        // the snapshot the digest describes (a mid-build edit), and
        // reporting the digest for those bytes would let a later
        // preflight treat the fingerprint as evidence about content
        // it was never computed from. The verification hash runs once
        // per asset per build; the memo above covers later visits.
        if (blake3Hex(utf8.encode(content)) == frontendDigest) {
          _learnedContents[key] = content;
          _learnedDigests[key] = frontendDigest;
          learned[key] = (
            digest: frontendDigest,
            fingerprint: cache.lookup(frontendDigest, package: id.package),
          );
          return;
        }
      }
    }
    final digest = blake3Hex(utf8.encode(content));
    _learnedContents[key] = content;
    if (_learnedDigests[key] == digest && learned.containsKey(key)) {
      return;
    }
    _learnedDigests[key] = digest;
    learned[key] = (
      digest: digest,
      fingerprint: parsed != null
          ? cache.fingerprintForParse(digest, parsed, package: id.package)
          : cache.fingerprintFor(digest, content, package: id.package),
    );
  }
}

/// An [AnalysisDriverModel] whose lock and library-cycle graph are owned by
/// the worker, so a resolver reset between Rust phases can keep the loaded
/// dependency graph instead of re-walking every known asset.
///
/// Source file dependencies cannot change during a build, and generated-file
/// entries in the graph are phase-scoped `PhasedValue`s which expire and
/// reload on their own, so keeping the graph across an in-build phase commit
/// is safe.
class WorkerAnalysisDriverModel extends AnalysisDriverModel {
  final _workerPool = Pool(1);
  PoolResource? _workerLock;

  final LibraryCycleGraphLoader _workerGraphLoader = LibraryCycleGraphLoader();
  final ApiFingerprintLedger _fingerprintLedger = ApiFingerprintLedger();

  @override
  Future<void> takeLockAndStartBuild({
    required BuilderFilesystem builderFilesystem,
    required BuildInputs buildInputs,
  }) async {
    _workerLock = await _workerPool.request();
    try {
      filesystem.startBuild(
        builderFilesystem: builderFilesystem,
        buildInputs: buildInputs,
      );
    } catch (_) {
      _workerLock?.release();
      _workerLock = null;
      rethrow;
    }
  }

  /// Clears build state and frees the lock taken by [takeLockAndStartBuild].
  ///
  /// With [clearGraph] false the loaded library-cycle graph is kept.
  void endBuildAndUnlock({bool clearGraph = true}) {
    if (clearGraph) _workerGraphLoader.clear();
    _workerLock?.release();
    _workerLock = null;
  }

  @override
  PhasedAssetDeps phasedAssetDeps() => _workerGraphLoader.phasedAssetDeps();

  /// Unit fingerprints the dep walk has learned for this driver model
  /// (ADR 0056), keyed by asset id string; a null fingerprint marks
  /// a unit whose fingerprint is unavailable. Owned by this instance's
  /// [ApiFingerprintLedger].
  Map<String, LearnedApiFingerprint> learnedApiFingerprints() =>
      _fingerprintLedger.learned;

  /// Clears the learned fingerprints and the learning memos on this
  /// instance's [ApiFingerprintLedger] at a build boundary (see
  /// [ApiFingerprintLedger.clear]).
  void clearLearnedApiFingerprints() => _fingerprintLedger.clear();

  /// Enables or disables API fingerprint learning for subsequent
  /// dep walks on this driver model (see
  /// [ApiFingerprintLedger.learningEnabled]).
  void setFingerprintLearningEnabled(bool enabled) =>
      _fingerprintLedger.learningEnabled = enabled;

  /// Whether API fingerprint learning is currently enabled on this
  /// driver model (see [setFingerprintLearningEnabled]).
  bool get fingerprintLearningEnabled => _fingerprintLedger.learningEnabled;

  /// Invalidates all fingerprint state for [ids], whose bytes a
  /// resolver reset updated or deleted (see
  /// [ApiFingerprintLedger.invalidate]).
  void invalidatePendingFingerprints(Iterable<AssetId> ids) =>
      _fingerprintLedger.invalidate(ids);

  /// Completes dep loads queued for [phase] or earlier.
  ///
  /// An expired `PhasedValue.unavailable` entry is queued in the loader's
  /// `_idsToLoad` and is re-loaded eagerly by the next `_load` at a late
  /// enough phase, under whichever action happens to run it. Draining the
  /// queue while no action owns the reader keeps those bookkeeping reload
  /// reads out of any action's observed reads; the completed deps still
  /// reach the dep graph exported for dependency-based invalidation.
  /// Fingerprint learning is suspended for the drain: these are
  /// bookkeeping loads owned by no action, so they must not learn
  /// under whatever action's opt-in happens to be active.
  Future<void> drainPendingDepLoads({
    required BuilderFilesystem builderFilesystem,
    required int phase,
  }) async {
    final deps = _workerGraphLoader.phasedAssetDeps();
    AssetId? id;
    for (final entry in deps.assetDeps.entries) {
      final expiresAfter = entry.value.expiresAfter;
      if (expiresAfter == null || expiresAfter >= phase) {
        id = entry.key;
        break;
      }
      id ??= entry.key;
    }
    if (id == null) return;
    final loader = _CachingAssetDepsLoader(
      builderFilesystem,
      phase,
      filesystem,
      _fingerprintLedger,
    );
    final wasEnabled = _fingerprintLedger.learningEnabled;
    _fingerprintLedger.learningEnabled = false;
    try {
      await _workerGraphLoader.libraryCycleGraphOf(loader, id);
    } finally {
      _fingerprintLedger.learningEnabled = wasEnabled;
    }
  }

  /// Computes the direct resolver deps of [id] from explicit [content]
  /// for an ADR 0056 preflight query. The caller read the content
  /// itself, so no build filesystem state is consulted for the unit;
  /// the loader records the unit's API fingerprint as a side effect,
  /// exactly as a dep-walk load would.
  List<AssetId> preflightUnitDeps(
    AssetId id,
    String content, {
    required BuilderFilesystem builderFilesystem,
    required int phase,
  }) {
    final loader = _CachingAssetDepsLoader(
      builderFilesystem,
      phase,
      filesystem,
      _fingerprintLedger,
    );
    return loader.depsForContent(id, content);
  }

  @override
  Future<void> updateDriver({
    required Future<void> Function(
      Future<void> Function(AnalysisDriverForPackageBuild),
    )
    withDriver,
    required BuildStepImpl buildStep,
    required AssetId entrypoint,
    required bool transitive,
  }) async {
    if (transitive) {
      await TimedActivity.resolve.runAsync(() async {
        final nodeLoader = _CachingAssetDepsLoader(
          buildStep.buildFilesystem,
          buildStep.phase,
          filesystem,
          _fingerprintLedger,
        );
        buildStep.inputTracker.addResolverEntrypoint(entrypoint);
        final walkTimer = resolverActionMetrics.enabled
            ? (Stopwatch()..start())
            : null;
        await _workerGraphLoader.libraryCycleGraphOf(nodeLoader, entrypoint);
        if (walkTimer != null) {
          resolverActionMetrics.cycleGraphWalkUs +=
              walkTimer.elapsedMicroseconds;
        }
      });
    } else {
      buildStep.inputTracker.add(entrypoint);
      await buildStep.canRead(entrypoint, track: false);
    }

    await withDriver((driver) async {
      await TimedActivity.resolve.runAsync(() async {
        final phaseTimer = resolverActionMetrics.enabled
            ? (Stopwatch()..start())
            : null;
        filesystem.phase = buildStep.phase;
        if (phaseTimer != null) {
          resolverActionMetrics.filesystemPhaseSyncUs +=
              phaseTimer.elapsedMicroseconds;
        }
      });

      if (filesystem.changedPaths.isNotEmpty) {
        for (final path in filesystem.changedPaths) {
          driver.changeFile(path);
        }
        filesystem.clearChangedPaths();
        final pendingTimer = resolverActionMetrics.enabled
            ? (Stopwatch()..start())
            : null;
        await TimedActivity.analyze.runAsync(driver.applyPendingFileChanges);
        if (pendingTimer != null) {
          resolverActionMetrics.applyPendingChangesUs +=
              pendingTimer.elapsedMicroseconds;
        }
      }
    });
  }
}

/// Counts dep loads so the breakdown can show how many assets the
/// first `libraryCycleGraphOf` walk covers, and serves parse results
/// through the shared content-keyed [AssetDepsCache].
///
/// The parent `AssetDepsLoader` keeps its filesystem in a private field, so
/// this loader re-implements `load`: it reads the phased content the same
/// way, then resolves each value's [AssetDeps] from the cache or by parsing
/// — mirroring the parent `_parse` exactly — while preserving each value's
/// `expiresAfter` phase. Caching by content is safe under phases because the
/// deps for a given content never change; the phase semantics live in the
/// `ExpiringValue` wrapper, not in the deps.
class _CachingAssetDepsLoader extends AssetDepsLoader {
  _CachingAssetDepsLoader(
    BuilderFilesystem filesystem,
    int phase,
    this._contentCache,
    this._fingerprintLedger,
  ) : _filesystem = filesystem,
      super(filesystem, phase);

  static const _ignoredSchemes = ['dart', 'dart-ext'];

  final BuilderFilesystem _filesystem;

  /// The driver's `AnalysisDriverFilesystem` as a [FileContentCache]: its
  /// `_data` entries already carry the md5 `contentHash` paid for during
  /// `contentOf`, letting dep lookups skip a second hash over the source.
  final FileContentCache? _contentCache;

  final ApiFingerprintLedger _fingerprintLedger;

  // Lazy: the first action pays the directory stat once; disabled via
  // `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0` stays `null`.
  static final AssetDepsCache? _cache = AssetDepsCache.shared();

  // Lazy like [_cache]; disabled by the same environment variable.
  static final ApiFingerprintCache? _fingerprintCache =
      ApiFingerprintCache.shared();

  /// Records the API fingerprint of the unit [id] with source
  /// [content] on [_fingerprintLedger] when learning is enabled.
  void _learnApiFingerprint(
    AssetId id,
    String content, {
    ParseStringResult? parsed,
    String? frontendDigest,
  }) {
    if (!_fingerprintLedger.learningEnabled) return;
    final cache = _fingerprintCache;
    if (cache == null) return;
    _fingerprintLedger.record(
      id,
      content,
      cache: cache,
      parsed: parsed,
      frontendDigest: frontendDigest,
    );
  }

  @override
  Future<PhasedValue<AssetDeps>> load(AssetId id) async {
    resolverActionMetrics.cycleGraphFileLoads++;
    // With a frontend-supplied digest (`asset-digests-v1`, ADR 0054) the
    // content-keyed deps cache can answer for the snapshot content
    // without parsing or hashing it here. `readPhased` below still runs:
    // it is also the Analyzer's content feed, so skipping it would leave
    // the driver without the library's content after a resolver reset.
    final filesystem = _filesystem;
    final cache = _cache;
    String? frontendDigest;
    AssetDeps? digestHit;
    if (filesystem is RemoteBuilderFilesystem && cache != null) {
      frontendDigest = filesystem.frontendDigestFor(id);
      if (frontendDigest != null) {
        digestHit = cache.lookup(cache.keyForDigest(id, frontendDigest));
        if (digestHit != null) {
          resolverActionMetrics.depParseCacheHits++;
          resolverActionMetrics.depDigestLoads++;
        }
      }
    }
    final traceLoads =
        resolverActionMetrics.enabled && resolverActionMetrics.traceEnabled;
    final readCacheHits = traceLoads
        ? resolverActionMetrics.ipcReadCacheHits
        : 0;
    final readRpcCalls = traceLoads ? resolverActionMetrics.ipcReadCalls : 0;
    final readTimer = resolverActionMetrics.enabled
        ? (Stopwatch()..start())
        : null;
    final content = await _filesystem.readPhased(phase, id);
    if (readTimer != null) {
      resolverActionMetrics.depReadPhasedUs += readTimer.elapsedMicroseconds;
    }
    if (traceLoads) {
      final fc = _contentCache?.get(id.asPath);
      resolverActionMetrics.depLoads.add({
        'asset': id.toString(),
        'phase': phase,
        'content_hash': content.values.last.value.isEmpty
            ? null
            : fc?.exists == true &&
                  identical(fc!.content, content.values.last.value)
            ? fc.contentHash
            : md5.convert(utf8.encode(content.values.last.value)).toString(),
        'expires_after': content.expiresAfter,
        'read_cache_hits':
            resolverActionMetrics.ipcReadCacheHits - readCacheHits,
        'read_rpc_calls': resolverActionMetrics.ipcReadCalls - readRpcCalls,
      });
    }
    if (digestHit != null && content.isComplete) {
      // The cached deps describe exactly the content `readPhased` just
      // fed to the Analyzer, and a source asset's deps never change
      // during a build, so the value is fixed. Prefetching the revealed
      // deps mirrors the slow path below.
      _learnApiFingerprint(
        id,
        content.values.last.value,
        frontendDigest: frontendDigest,
      );
      if (filesystem is RemoteBuilderFilesystem) {
        await filesystem.prefetchDepReads(digestHit.deps);
      }
      return PhasedValue.fixed(digestHit);
    }
    final result = PhasedValue<AssetDeps>((b) {
      for (final expiring in content.values) {
        b.values.add(
          ExpiringValue<AssetDeps>(
            // An incomplete read carries expiring placeholder values
            // (an empty string for an asset unreadable in that phase),
            // which are not the snapshot bytes the frontend digest
            // describes; only a complete read may use it, mirroring
            // the digest fast path above.
            _depsFor(
              id,
              expiring.value,
              frontendDigest: content.isComplete ? frontendDigest : null,
            ),
            expiresAfter: expiring.expiresAfter,
          ),
        );
      }
    });
    // Warm the frontend-digest key so later workers and builds can take
    // the fast path above: store only when the digest computed here over
    // the content actually read equals the frontend's, keeping every
    // stored entry bound to bytes a worker hashed itself.
    if (frontendDigest != null && cache != null && result.isComplete) {
      final contentDigest = blake3Hex(utf8.encode(content.values.last.value));
      if (contentDigest == frontendDigest) {
        cache.store(cache.keyForDigest(id, frontendDigest), result.lastValue);
      }
    }
    // Batch-resolve the deps this file just revealed so the walk's upcoming
    // readPhased calls hit the shared read/readable caches warmed by a single
    // `resolve_assets` round-trip per dep frontier instead of a
    // `can_read` + `read` pair per asset. Unavailable values hold no deps to
    // read yet, so only complete results are prefetched.
    if (result.isComplete && filesystem is RemoteBuilderFilesystem) {
      await filesystem.prefetchDepReads(result.lastValue.deps);
    }
    return result;
  }

  /// Runs the content-keyed deps computation for explicit [content]
  /// (ADR 0056 preflight); see
  /// [WorkerAnalysisDriverModel.preflightUnitDeps].
  List<AssetId> depsForContent(AssetId id, String content) =>
      _depsFor(id, content).deps.toList();

  AssetDeps _depsFor(AssetId id, String content, {String? frontendDigest}) {
    if (content.isEmpty) {
      // A unit that became empty still has a current fingerprint (or
      // an unavailable marker); learning it replaces the fingerprint
      // of its previous, nonempty content.
      _learnApiFingerprint(id, content, frontendDigest: frontendDigest);
      return AssetDeps.empty;
    }
    final cache = _cache;
    if (cache == null) {
      final (deps, parsed) = _parseWithResult(id, content);
      _learnApiFingerprint(
        id,
        content,
        parsed: parsed,
        frontendDigest: frontendDigest,
      );
      return deps;
    }
    final timer = resolverActionMetrics.enabled ? (Stopwatch()..start()) : null;
    // `readPhased` just stored this exact `content` string instance in the
    // driver filesystem's `_data` along with its md5 `contentHash`; when the
    // FileContent lookup provably returns that same instance, the digest key
    // skips re-hashing ~8KB of source. Otherwise fall back to hashing.
    final fc = _contentCache?.get(id.asPath);
    final key = fc != null && fc.exists && identical(fc.content, content)
        ? cache.keyForDigest(id, fc.contentHash)
        : cache.keyFor(id, content);
    final hit = cache.lookup(key);
    if (hit != null) {
      resolverActionMetrics.depParseCacheHits++;
      if (timer != null) {
        resolverActionMetrics.depParseCacheUs += timer.elapsedMicroseconds;
      }
      _learnApiFingerprint(id, content, frontendDigest: frontendDigest);
      return hit;
    }
    resolverActionMetrics.depParseCacheMisses++;
    final parseTimer = resolverActionMetrics.enabled
        ? (Stopwatch()..start())
        : null;
    final (deps, parsed) = _parseWithResult(id, content);
    if (parseTimer != null) {
      resolverActionMetrics.depParseUs += parseTimer.elapsedMicroseconds;
    }
    cache.store(key, deps);
    _learnApiFingerprint(
      id,
      content,
      parsed: parsed,
      frontendDigest: frontendDigest,
    );
    if (timer != null) {
      resolverActionMetrics.depParseCacheUs += timer.elapsedMicroseconds;
    }
    return deps;
  }

  // Same directive scan as `AssetDepsLoader._parse`. The parse result
  // rides along so the API fingerprint (ADR 0056) reuses this parse
  // instead of parsing the unit a second time. The parse uses the
  // package's language version feature set when it is recorded, so
  // the fingerprint is computed from the grammar the resolver itself
  // parses with; without a recorded version the parse falls back to
  // the latest grammar for the directive scan and no fingerprint is
  // learned from it.
  (AssetDeps, ParseStringResult) _parseWithResult(AssetId id, String content) {
    final depsNodeBuilder = AssetDepsBuilder();
    final result = parseString(
      content: content,
      featureSet: apiFingerprintFeatureSet(id.package),
      throwIfDiagnostics: false,
    );
    final parsed = result.unit;
    for (final directive in parsed.directives) {
      if (directive is! UriBasedDirective) continue;
      final uri = directive.uri.stringValue;
      if (uri == null) continue;
      final parsedUri = Uri.parse(uri);
      if (_ignoredSchemes.any(parsedUri.isScheme)) continue;
      depsNodeBuilder.deps.add(AssetId.resolve(parsedUri, from: id));
    }
    return (depsNodeBuilder.build(), result);
  }
}
