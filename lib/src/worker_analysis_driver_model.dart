import 'dart:async';

// ignore: implementation_imports
import 'package:analyzer/src/clients/build_resolvers/build_resolvers.dart';
import 'package:build/build.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/build_step_impl.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/builder_filesystem.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/asset_deps_loader.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/library_cycle_graph_loader.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/phased_asset_deps.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/analysis_driver_model.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build_plan/build_inputs.dart';
// ignore: implementation_imports
import 'package:build_runner/src/logging/timed_activities.dart';
import 'package:pool/pool.dart';

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
    final loader = AssetDepsLoader(builderFilesystem, phase);
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
        final nodeLoader = AssetDepsLoader(
          buildStep.buildFilesystem,
          buildStep.phase,
        );
        buildStep.inputTracker.addResolverEntrypoint(entrypoint);
        await _workerGraphLoader.libraryCycleGraphOf(nodeLoader, entrypoint);
      });
    } else {
      buildStep.inputTracker.add(entrypoint);
      await buildStep.canRead(entrypoint, track: false);
    }

    await withDriver((driver) async {
      await TimedActivity.resolve.runAsync(() async {
        filesystem.phase = buildStep.phase;
      });

      if (filesystem.changedPaths.isNotEmpty) {
        for (final path in filesystem.changedPaths) {
          driver.changeFile(path);
        }
        filesystem.clearChangedPaths();
        await TimedActivity.analyze.runAsync(driver.applyPendingFileChanges);
      }
    });
  }
}
