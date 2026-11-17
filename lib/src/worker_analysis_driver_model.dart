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

  /// Unit fingerprints the dep walk has learned in this process
  /// (ADR 0056), keyed by asset id string; a null value marks a unit
  /// whose fingerprint is unavailable.
  Map<String, String?> learnedApiFingerprints() =>
      _CachingAssetDepsLoader.learnedApiFingerprints;

  /// Completes dep loads queued for [phase] or earlier.
  ///
  /// An expired `PhasedValue.unavailable` entry is queued in the loader's
  /// `_idsToLoad` and is re-loaded eagerly by the next `_load` at a late
  /// enough phase, under whichever action happens to run it. Draining the
  /// queue while no action owns the reader keeps those bookkeeping reload
  /// reads out of any action's observed reads; the completed deps still
  /// reach the dep graph exported for dependency-based invalidation.
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
    );
    await _workerGraphLoader.libraryCycleGraphOf(loader, id);
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
  ) : _filesystem = filesystem,
      super(filesystem, phase);

  static const _ignoredSchemes = ['dart', 'dart-ext'];

  final BuilderFilesystem _filesystem;

  /// The driver's `AnalysisDriverFilesystem` as a [FileContentCache]: its
  /// `_data` entries already carry the md5 `contentHash` paid for during
  /// `contentOf`, letting dep lookups skip a second hash over the source.
  final FileContentCache? _contentCache;

  // Lazy: the first action pays the directory stat once; disabled via
  // `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0` stays `null`.
  static final AssetDepsCache? _cache = AssetDepsCache.shared();

  // Lazy like [_cache]; disabled by the same environment variable.
  static final ApiFingerprintCache? _fingerprintCache =
      ApiFingerprintCache.shared();

  /// Unit fingerprints learned by dep walks in this process, keyed by
  /// asset id string (ADR 0056); a null value marks a unit whose
  /// fingerprint is unavailable. Reported to the frontend with the
  /// build results, delta-encoded against what it already has, like
  /// the dep graph.
  static final Map<String, String?> learnedApiFingerprints =
      <String, String?>{};

  /// Records the API fingerprint of the unit [id] with source
  /// [content] as learned. [parsed] reuses the dep walk's own parse
  /// when it has one; without it the fingerprint cache answers, and
  /// parses on a miss.
  static void _learnApiFingerprint(
    AssetId id,
    String content, [
    ParseStringResult? parsed,
  ]) {
    final cache = _fingerprintCache;
    if (cache == null) return;
    final digest = blake3Hex(utf8.encode(content));
    learnedApiFingerprints[id.toString()] = parsed != null
        ? cache.fingerprintForParse(digest, parsed)
        : cache.fingerprintFor(digest, content);
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
      _learnApiFingerprint(id, content.values.last.value);
      if (filesystem is RemoteBuilderFilesystem) {
        await filesystem.prefetchDepReads(digestHit.deps);
      }
      return PhasedValue.fixed(digestHit);
    }
    final result = PhasedValue<AssetDeps>((b) {
      for (final expiring in content.values) {
        b.values.add(
          ExpiringValue<AssetDeps>(
            _depsFor(id, expiring.value),
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

  AssetDeps _depsFor(AssetId id, String content) {
    if (content.isEmpty) return AssetDeps.empty;
    final cache = _cache;
    if (cache == null) {
      final (deps, parsed) = _parseWithResult(id, content);
      _learnApiFingerprint(id, content, parsed);
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
      _learnApiFingerprint(id, content);
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
    _learnApiFingerprint(id, content, parsed);
    if (timer != null) {
      resolverActionMetrics.depParseCacheUs += timer.elapsedMicroseconds;
    }
    return deps;
  }

  // Same directive scan as `AssetDepsLoader._parse`. The parse result
  // rides along so the API fingerprint (ADR 0056) reuses this parse
  // instead of parsing the unit a second time.
  (AssetDeps, ParseStringResult) _parseWithResult(AssetId id, String content) {
    final depsNodeBuilder = AssetDepsBuilder();
    final result = parseString(content: content, throwIfDiagnostics: false);
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
