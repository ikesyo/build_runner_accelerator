import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:build_runner/src/build/asset_content.dart' show AssetContent;
import 'package:build_runner/src/build/library_cycle_graph/phased_asset_deps.dart'
    show PhasedAssetDeps;
import 'package:build_runner/src/build_plan/build_inputs.dart' show BuildInputs;
import 'package:package_config/package_config.dart';

import 'overlay_blob.dart';
import 'reset_directives.dart';
import 'worker_runtime.dart';

final _resetTraceEnabled =
    Platform.environment['BUILD_RUNNER_ACCELERATOR_WALL_TRACE'] == '1';

class WorkerResetState {
  /// Directive lines (`import`/`export`/`part`/`part of`/`library`) of Dart
  /// assets committed to the overlay while this worker is alive. The
  /// library-cycle loader caches parsed directives per asset, so a committed
  /// asset whose directives changed invalidates that cache. Content-only
  /// regeneration keeps the cached entry accurate and does not need a graph
  /// clear.
  final Map<String, Set<String>> committedDartDirectives =
      <String, Set<String>>{};

  // Workspace leases can replay the same overlay after reinitializing for a
  // different package. Only the extraction is reusable across those contexts.
  Map<AssetId, ResetDirectiveContent> previousOverlayExtractions = const {};

  final Set<String> resetDirectiveContents = <String>{};

  void clearForNewBuild() {
    committedDartDirectives.clear();
    resetDirectiveContents.clear();
  }

  void clearOverlayExtractions() {
    previousOverlayExtractions = const {};
  }
}

Future<void> runResetResolver({
  required WorkerRuntime runtime,
  Set<AssetId> updatedSources = const <AssetId>{},
  Set<AssetId> deletedSources = const <AssetId>{},
  Set<AssetId> updatedCache = const <AssetId>{},
  Set<AssetId> deletedCache = const <AssetId>{},
  bool incremental = false,
  Map<String, Object?>? overlayBlob,
}) async {
  if (!runtime.buildStarted) return;
  final resetTimer = _resetTraceEnabled ? (Stopwatch()..start()) : null;
  final differ = _ResetDirectiveDiffer(
    resetTimer: resetTimer,
    directiveTimer: runtime.resolverProfile.enabled ? resetTimer : null,
    packageConfig: runtime.packageConfig,
    state: runtime.resetState,
  );

  // Validate and read transport before mutating phase state.
  // A single worker keeps its produced outputs in memory without a blob.
  final transported = overlayBlob == null
      ? null
      : readOverlayBlob(overlayBlob, {...updatedSources, ...updatedCache});
  runtime.resolverDependencyCache.clear();
  final changedAssets = <AssetId>{
    ...updatedSources,
    ...deletedSources,
    ...updatedCache,
    ...deletedCache,
  };
  for (final id in changedAssets) {
    runtime.readCache.remove(id);
    runtime.readableCache.remove(id);
  }
  runtime.resolver.invalidatePendingFingerprints(changedAssets);
  // The frontend drops the recorded fingerprints for these
  // assets; if a later action relearns one and lands on the same
  // fingerprint (a body-only change), the sent delta must not
  // suppress the re-report.
  for (final id in changedAssets) {
    runtime.sentApiFingerprints.remove(id.toString());
  }
  for (final id in deletedSources.followedBy(deletedCache)) {
    runtime.producedOutputs.remove(id);
  }
  differ.mark('cache_invalidation');
  if (transported != null) {
    for (final id in updatedSources.followedBy(updatedCache)) {
      final bytes = transported[id];
      if (bytes != null) {
        runtime.producedOutputs[id] = AssetContent.bytes(bytes);
      } else {
        // An absent index entry must not resurrect a previous overlay value.
        runtime.producedOutputs.remove(id);
      }
    }
  }
  if (!incremental) {
    await runtime.restartCleanAfterReset();
    return;
  }
  differ.mark('overlay_read');
  for (final id in updatedSources.followedBy(updatedCache)) {
    if (runtime.producedOutputs.containsKey(id)) continue;
    await runtime.restartCleanAfterReset();
    return;
  }
  final diff = differ.diffDirectives(
    updated: updatedSources.followedBy(updatedCache),
    deleted: deletedSources.followedBy(deletedCache),
    producedOutputs: runtime.producedOutputs,
    fromBlob: transported != null,
    loadDepGraph: runtime.resolver.phasedAssetDeps,
  );
  final endStart = differ.tick();
  runtime.resolver.reset(clearGraph: diff.dartGraphChanged);
  differ.timed('graph_end_us', endStart);
  differ.mark('directives_and_graph');
  await runtime.restartIncrementalAfterReset(
    BuildInputs((builder) {
      builder.cleanBuild = false;
      // Cache-tree Dart assets are Analyzer-visible too (generated sources
      // of dependency packages), so they refresh the same in-memory view.
      builder.updatedSources.addAll(updatedSources.followedBy(updatedCache));
      builder.deletedSources.addAll(deletedSources.followedBy(deletedCache));
    }),
  );
  runtime.resetState.previousOverlayExtractions = diff.overlayExtractions;
  differ.mark('analyzer_start');
  differ.emitTrace(
    updatedCount: updatedSources.length + updatedCache.length,
    deletedCount: deletedSources.length + deletedCache.length,
    graphCleared: diff.dartGraphChanged,
  );
}

class _ResetDirectiveDiffer {
  _ResetDirectiveDiffer({
    required Stopwatch? resetTimer,
    required Stopwatch? directiveTimer,
    required PackageConfig packageConfig,
    required WorkerResetState state,
  }) : _resetTimer = resetTimer,
       _directiveTimer = directiveTimer,
       _packageConfig = packageConfig,
       _state = state;

  static const _maxOverlayExtractions = 4096;
  static const _maxOverlayCodeUnits = 16 * 1024 * 1024;

  final Stopwatch? _resetTimer;
  final Stopwatch? _directiveTimer;
  final PackageConfig _packageConfig;
  final WorkerResetState _state;
  final Map<String, int> _stages = <String, int>{};
  final Map<String, int> _directiveStats = <String, int>{};

  void mark(String stage) {
    final timer = _resetTimer;
    if (timer != null) _stages[stage] = timer.elapsedMicroseconds;
  }

  int tick() => _directiveTimer?.elapsedMicroseconds ?? 0;

  void _count(String name, [int amount = 1]) {
    if (_directiveTimer != null) {
      _directiveStats.update(
        name,
        (value) => value + amount,
        ifAbsent: () => amount,
      );
    }
  }

  void timed(String name, int start) => _count(name, tick() - start);

  ResetDirectiveContent _extract(
    AssetContent content,
    String lane, {
    ResetDirectiveContent? equivalent,
  }) {
    if (_directiveTimer == null) {
      final text = content.stringValue();
      return equivalent?.reuse(text) ?? ResetDirectiveContent(text);
    }
    final start = tick();
    final text = content.stringValue();
    timed('${lane}_decode_us', start);
    _count('${lane}_bytes', content.bytes.length);
    _count('${lane}_extract_requests');
    if (!_state.resetDirectiveContents.add(text)) {
      _count('repeated_content_extracts');
    }
    final compareStart = tick();
    final reused = equivalent?.reuse(text);
    timed('${lane}_content_compare_us', compareStart);
    if (reused != null) {
      _count('${lane}_same_content_reuses');
      return reused;
    }
    _count('${lane}_extracts');
    final scanStart = tick();
    final result = ResetDirectiveContent(text);
    timed('${lane}_scan_us', scanStart);
    return result;
  }

  Set<String>? _onDisk(AssetId id, ResetDirectiveContent current) {
    final start = tick();
    final package = _packageConfig.packages
        .where((p) => p.name == id.package && p.root.isScheme('file'))
        .firstOrNull;
    timed('old_lookup_us', start);
    if (package == null) return null;
    final existsStart = tick();
    final file = File.fromUri(package.root.resolve(id.path));
    final exists = file.existsSync();
    _count('old_exists_checks');
    timed('old_exists_us', existsStart);
    if (!exists) return null;
    final readStart = tick();
    final bytes = file.readAsBytesSync();
    _count('old_reads');
    timed('old_read_us', readStart);
    return _extract(
      AssetContent.bytes(bytes),
      'old',
      equivalent: current,
    ).directives;
  }

  ({
    bool dartGraphChanged,
    Map<AssetId, ResetDirectiveContent> overlayExtractions,
  })
  diffDirectives({
    required Iterable<AssetId> updated,
    required Iterable<AssetId> deleted,
    required Map<AssetId, AssetContent> producedOutputs,
    required bool fromBlob,
    required PhasedAssetDeps Function() loadDepGraph,
  }) {
    final overlayExtractions = <AssetId, ResetDirectiveContent>{};
    var overlayCodeUnits = 0;
    // A committed Dart asset whose directive set changed can change the
    // import graph: the cycle loader caches parsed directives per asset, so
    // keeping the graph would let the resolver reuse stale dependencies.
    // Content-only regeneration keeps the cached entry accurate. A deleted
    // asset leaves dependents' directives untouched, so their cached cycles
    // stay as valid as they are under a clear.
    var dartGraphChanged = false;
    PhasedAssetDeps? depGraph;
    for (final id in updated) {
      if (!id.path.endsWith('.dart') && !id.path.endsWith('.part')) {
        continue;
      }
      final key = '${id.package}|${id.path}';
      final current = _extract(
        producedOutputs[id]!,
        'updated',
        equivalent: fromBlob ? _state.previousOverlayExtractions[id] : null,
      );
      final codeUnits = current.content.length;
      if (fromBlob &&
          overlayExtractions.length < _maxOverlayExtractions &&
          codeUnits <= _maxOverlayCodeUnits - overlayCodeUnits) {
        overlayExtractions[id] = current;
        overlayCodeUnits += codeUnits;
      }
      final directives = current.directives;
      final oldCacheStart = tick();
      final cached = _state.committedDartDirectives[key];
      timed('old_cache_lookup_us', oldCacheStart);
      _count(cached == null ? 'old_cache_misses' : 'old_cache_hits');
      final previous = cached ?? _onDisk(id, current);
      if (previous != null) {
        final compareStart = tick();
        final same = _sameDirectives(previous, directives);
        timed('compare_us', compareStart);
        _count('comparisons');
        if (!same) {
          dartGraphChanged = true;
        }
      } else if (directives.isNotEmpty) {
        // With no earlier record, an asset that was dependency-loaded
        // while still missing may hold a stale empty-deps entry. Entries
        // with an expiry reload on the next read on their own; only a
        // permanent (`fixed`) entry leaves the graph stale.
        final depStart = tick();
        _count('dep_lookups');
        depGraph ??= loadDepGraph();
        final recorded = depGraph.assetDeps[id];
        timed('dep_lookup_us', depStart);
        if (recorded != null &&
            recorded.expiresAfter == null &&
            recorded.values.last.value.deps.isEmpty) {
          dartGraphChanged = true;
        }
      }
      _state.committedDartDirectives[key] = directives;
    }
    for (final id in deleted) {
      _state.committedDartDirectives.remove('${id.package}|${id.path}');
    }
    return (
      dartGraphChanged: dartGraphChanged,
      overlayExtractions: overlayExtractions,
    );
  }

  void emitTrace({
    required int updatedCount,
    required int deletedCount,
    required bool graphCleared,
  }) {
    if (_resetTimer == null) return;
    stderr.writeln(
      'BRA_RESET_TRACE ${jsonEncode({'pid': pid, 'updated': updatedCount, 'deleted': deletedCount, 'graph_cleared': graphCleared, 'elapsed_us': _stages, 'directive_stats': _directiveStats})}',
    );
  }

  static bool _sameDirectives(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
