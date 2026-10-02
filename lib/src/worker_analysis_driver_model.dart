import 'dart:async';

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
import 'package:build_runner/src/build/resolver/analysis_driver_model.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build_plan/build_inputs.dart';
// ignore: implementation_imports
import 'package:build_runner/src/logging/timed_activities.dart';
import 'package:pool/pool.dart';

import 'asset_deps_cache.dart';
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
    final loader = _CachingAssetDepsLoader(builderFilesystem, phase);
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
  _CachingAssetDepsLoader(BuilderFilesystem filesystem, int phase)
    : _filesystem = filesystem,
      super(filesystem, phase);

  static const _ignoredSchemes = ['dart', 'dart-ext'];

  final BuilderFilesystem _filesystem;

  // Lazy: the first action pays the directory stat once; disabled via
  // `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0` stays `null`.
  static final AssetDepsCache? _cache = AssetDepsCache.shared();

  @override
  Future<PhasedValue<AssetDeps>> load(AssetId id) async {
    resolverActionMetrics.cycleGraphFileLoads++;
    final readTimer = resolverActionMetrics.enabled
        ? (Stopwatch()..start())
        : null;
    final content = await _filesystem.readPhased(phase, id);
    if (readTimer != null) {
      resolverActionMetrics.depReadPhasedUs += readTimer.elapsedMicroseconds;
    }
    return PhasedValue((b) {
      for (final expiring in content.values) {
        b.values.add(
          ExpiringValue<AssetDeps>(
            _depsFor(id, expiring.value),
            expiresAfter: expiring.expiresAfter,
          ),
        );
      }
    });
  }

  AssetDeps _depsFor(AssetId id, String content) {
    if (content.isEmpty) return AssetDeps.empty;
    final cache = _cache;
    if (cache == null) return _parse(id, content);
    final timer = resolverActionMetrics.enabled ? (Stopwatch()..start()) : null;
    final key = cache.keyFor(id, content);
    final hit = cache.lookup(key);
    if (hit != null) {
      resolverActionMetrics.depParseCacheHits++;
      if (timer != null) {
        resolverActionMetrics.depParseCacheUs += timer.elapsedMicroseconds;
      }
      return hit;
    }
    resolverActionMetrics.depParseCacheMisses++;
    final parseTimer = resolverActionMetrics.enabled
        ? (Stopwatch()..start())
        : null;
    final deps = _parse(id, content);
    if (parseTimer != null) {
      resolverActionMetrics.depParseUs += parseTimer.elapsedMicroseconds;
    }
    cache.store(key, deps);
    if (timer != null) {
      resolverActionMetrics.depParseCacheUs += timer.elapsedMicroseconds;
    }
    return deps;
  }

  // Same directive scan as `AssetDepsLoader._parse`.
  AssetDeps _parse(AssetId id, String content) {
    final depsNodeBuilder = AssetDepsBuilder();
    final parsed = parseString(
      content: content,
      throwIfDiagnostics: false,
    ).unit;
    for (final directive in parsed.directives) {
      if (directive is! UriBasedDirective) continue;
      final uri = directive.uri.stringValue;
      if (uri == null) continue;
      final parsedUri = Uri.parse(uri);
      if (_ignoredSchemes.any(parsedUri.isScheme)) continue;
      depsNodeBuilder.deps.add(AssetId.resolve(parsedUri, from: id));
    }
    return depsNodeBuilder.build();
  }
}
