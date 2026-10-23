import 'package:build/build.dart';
import 'package:build_runner/src/bootstrap/processes.dart' show ChildProcess;
import 'package:built_collection/built_collection.dart';
import 'package:build_runner/src/build/asset_content.dart' show AssetContent;
import 'package:build_runner/src/build/builder_filesystem.dart'
    show BuilderFilesystem, AssetContentExtension;
import 'package:build_runner/src/build/build_state/build_state.dart'
    show BuildState;
import 'package:build_runner/src/build/build_state/build_step_id.dart'
    show BuildStepId;
import 'package:build_runner/src/build_plan/build_configs.dart'
    show BuildConfigs;
import 'package:build_runner/src/build_plan/build_phases.dart' show BuildPhases;
import 'package:build_runner/src/build_plan/build_inputs.dart' show BuildInputs;
import 'package:build_runner/src/build_plan/build_package.dart'
    show BuildPackage;
import 'package:build_runner/src/build_plan/build_packages.dart'
    show BuildPackages;
import 'package:build_runner/src/build_plan/build_step_plan.dart'
    show BuildStepPlan;
import 'package:build_runner/src/build_plan/placeholders.dart'
    show Placeholders;
import 'package:build_runner/src/build/build_state/glob_id.dart' show GlobId;
import 'package:build_runner/src/build/library_cycle_graph/phased_value.dart'
    show PhasedValue;
import 'package:glob/glob.dart';
import 'package:package_config/package_config.dart';

import 'remote_build_step.dart';
import 'resolver_metrics.dart';

/// Creates the minimal current build_runner package view required by a
/// worker. The Rust frontend already owns package dependency resolution; all
/// package-config entries are therefore made visible to the resolver, with
/// the initialized package as the only output package.
BuildPackages buildPackagesFor(
  PackageConfig packageConfig,
  String currentPackage,
) {
  final packageNames = packageConfig.packages
      .map((package) => package.name)
      .toSet();
  if (!packageNames.contains(currentPackage)) {
    throw StateError(
      'Worker package $currentPackage is not present in package_config.json',
    );
  }

  final packages = <String, BuildPackage>{
    for (final package in packageConfig.packages)
      package.name: BuildPackage(
        name: package.name,
        path: package.root.toFilePath(),
        isOutput: package.name == currentPackage,
        languageVersion: package.languageVersion,
        dependencies: package.name == currentPackage
            ? packageNames.where((name) => name != currentPackage)
            : const <String>[],
      ),
  };
  return BuildPackages.compute(
    currentPackage: currentPackage,
    singlePackageToBuild: currentPackage,
    outputRoot: currentPackage,
    packages: packages.build(),
  );
}

BuildInputs cleanBuildInputs() => BuildInputs((builder) {
  builder.cleanBuild = true;
});

BuildStepPlan _emptyBuildStepPlan(int phaseCount) {
  final emptyPhase = ListBuilder<BuildStepId>().build();
  return BuildStepPlan((builder) {
    builder.buildPhases = BuildPhases(const []);
    builder.buildStepsByPhase.addAll(
      List<BuiltList<BuildStepId>>.filled(
        phaseCount < 1 ? 1 : phaseCount,
        emptyPhase,
      ),
    );
  });
}

/// A BuildState which treats the package-config namespace as a lazy remote
/// source set. Asset existence remains an RPC decision, so the worker does not
/// need to scan every dependency package before the first resolver request.
class RemoteBuildState implements BuildState {
  RemoteBuildState(
    this._packages, {
    required int phaseCount,
    Map<AssetId, AssetContent> committedContents = const {},
  }) : buildStepPlan = _emptyBuildStepPlan(phaseCount),
       _committedContents = Map.unmodifiable(committedContents),
       _sourceContents = Map.of(committedContents);

  final Set<String> _packages;
  // The Rust planner owns declared outputs and visibility. This plan supplies
  // only phase dimensions to the upstream Analyzer filesystem.
  final BuildStepPlan buildStepPlan;
  final Map<AssetId, AssetContent> _committedContents;
  final Map<AssetId, AssetContent?> _sourceContents;

  AssetContent? committedContentOf(AssetId id) => _committedContents[id];

  @override
  Iterable<AssetId> get sources => _committedContents.keys;

  @override
  bool isSource(AssetId id) => _packages.contains(id.package);

  @override
  bool isMissingSource(AssetId id) => false;

  @override
  void addMissingSource(AssetId id) {}

  AssetContent? contentOfSource(AssetId id) => _sourceContents[id];

  @override
  void updateSourceContent(AssetId id, AssetContent? content) {
    if (!isSource(id)) {
      throw StateError('Tried to update content of non-source $id.');
    }
    _sourceContents[id] = content;
  }

  // build_runner 2.16.0 takes contentOf(id: id, buildStepPlan: plan);
  // 2.16.1 takes contentOf(id). Interface forwarders preserve each upstream
  // signature while this single bridge handles only that known API change.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final positional = invocation.positionalArguments;
    final named = invocation.namedArguments;
    final current = positional.length == 1 && named.isEmpty;
    final legacy =
        positional.isEmpty &&
        named.containsKey(#id) &&
        named.keys.every((key) => key == #id || key == #buildStepPlan);
    if (invocation.isMethod &&
        invocation.memberName == #contentOf &&
        (current || legacy)) {
      final id = invocation.positionalArguments.isNotEmpty
          ? invocation.positionalArguments.single as AssetId
          : invocation.namedArguments[#id] as AssetId;
      return committedContentOf(id);
    }
    throw UnsupportedError(
      'Unsupported build_runner state API: ${invocation.memberName}',
    );
  }
}

/// Adapts current build_runner's visibility and Analyzer filesystem hooks to
/// the Rust-backed ReaderWriter. The empty plan is intentional: Rust owns the
/// declared-output index, phase visibility, and source/cache location, while
/// [RemoteAssetReaderWriter] enforces the current action's blocked logical-ID
/// set for the Dart-facing APIs.
class RemoteBuilderFilesystem implements BuilderFilesystem {
  RemoteBuilderFilesystem({
    required this.buildPackages,
    required this.buildState,
    required RemoteAssetReaderWriter readerWriter,
    required Map<String, List<Glob>> inputRestrictions,
  }) : _remoteReaderWriter = readerWriter,
       _inputRestrictions = inputRestrictions;

  @override
  final BuildPackages buildPackages;
  @override
  final RemoteBuildState buildState;
  @override
  BuildStepPlan get buildStepPlan => buildState.buildStepPlan;
  @override
  RemoteAssetReaderWriter get readerWriter => _remoteReaderWriter;
  @override
  // ignore: invalid_use_of_visible_for_testing_member
  final BuildConfigs buildConfigs = BuildConfigs.empty();
  @override
  Future<void> Function(AssetId) get assetBuilder => (_) async {};
  @override
  Future<void> Function(GlobId) get globEvaluator => (_) async {};

  final RemoteAssetReaderWriter _remoteReaderWriter;
  final Map<String, List<Glob>> _inputRestrictions;

  void Function(AssetId, AssetContent?)? _contentListener;

  @override
  void listenToContentUpdates(
    void Function(AssetId, AssetContent?) onUpdateContent,
  ) {
    if (_contentListener != null) {
      throw StateError('Already listening to content updates.');
    }
    _contentListener = onUpdateContent;
  }

  @override
  Future<AssetContent> contentOf(AssetId id) async {
    final committed = buildState.committedContentOf(id);
    if (committed != null) return committed;
    if (!buildState.isSource(id)) {
      throw StateError(
        'Cannot read $id, it is not a known source or generated output.',
      );
    }
    late List<int> bytes;
    try {
      bytes = await _remoteReaderWriter.readAsBytes(id);
    } on AssetNotFoundException {
      await ChildProcess.exitDueToAssetDeleted(id);
    }
    final content = AssetContent.bytes(bytes);
    buildState.updateSourceContent(id, content);
    _contentListener?.call(id, content);
    return content;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unsupported build_runner filesystem API: ${invocation.memberName}',
  );

  /// Dep loads avoid the builder-facing byte copy. Public contentOf/readAsBytes
  /// keep the mutable-copy behavior of stock reads.
  Future<AssetContent> _contentOfForDeps(AssetId id) async {
    final committed = buildState.committedContentOf(id);
    if (committed != null) return committed;
    if (!buildState.isSource(id)) {
      throw StateError(
        'Cannot read $id, it is not a known source or generated output.',
      );
    }
    final timer = resolverActionMetrics.enabled ? (Stopwatch()..start()) : null;
    late AssetContent content;
    try {
      // Read the action-visible snapshot first. Never use an AssetId-only
      // content cache: blocked/primary-input checks and observedReads must run
      // before using even an already-cached byte snapshot.
      final snapshot = await _remoteReaderWriter.readContent(id);
      if (resolverActionMetrics.enabled) {
        resolverActionMetrics.depContentSnapshotBytes += snapshot.bytes.length;
      }
      content = AssetContent.bytes(snapshot.bytes);
    } on AssetNotFoundException {
      await ChildProcess.exitDueToAssetDeleted(id);
    }
    if (timer != null) {
      resolverActionMetrics.depContentCalls++;
      resolverActionMetrics.depContentUs += timer.elapsedMicroseconds;
      timer.reset();
      // Split the work normally performed by the Analyzer content listener.
      // Invalid UTF-8 remains reported by that listener, as before.
      try {
        content.stringValue();
      } on FormatException {
        /* listener logs */
      }
      // Non-Dart assets do not enter the Analyzer content listener: avoid
      // introducing a diagnostic-only hash that their normal read never pays.
      if (id.extension == '.dart') content.digest;
      resolverActionMetrics.depContentDecodeHashUs += timer.elapsedMicroseconds;
      timer.reset();
    }
    // Replaying both updates is required, especially after a clean resolver
    // reset with a warm read cache but an empty Analyzer filesystem.
    buildState.updateSourceContent(id, content);
    _contentListener?.call(id, content);
    if (timer != null) {
      resolverActionMetrics.depContentUpdateUs += timer.elapsedMicroseconds;
    }
    return content;
  }

  /// Pre-resolves dep ids the loader is about to `readPhased` so the batched
  /// `resolve_assets` RPC can warm the reader's caches in one round-trip.
  ///
  /// Committed contents are served from `buildState.contentOf` ahead of the
  /// reader's caches, so they are excluded here to keep the caches identical
  /// to the sequential path.
  Future<void> prefetchDepReads(Iterable<AssetId> ids) =>
      _remoteReaderWriter.prefetchAssets(
        ids.where((id) => buildState.committedContentOf(id) == null),
      );

  @override
  void checkInvalidInput(AssetId id) {
    if (buildPackages[id.package] == null) {
      throw PackageNotFoundException(id.package);
    }
    final patterns = _inputRestrictions[id.package];
    if (patterns != null && !patterns.any((glob) => glob.matches(id.path))) {
      throw InvalidInputException(
        id,
        allowedGlobs: [for (final glob in patterns) glob.pattern],
      );
    }
  }

  /// The build plan declares no outputs, so the inherited implementation
  /// records a missing asset as `fixed('')` — a dep-graph entry the loader
  /// never reloads even after the asset gets generated. Give the empty value
  /// the current phase as expiry instead, so a later-phase load sees the
  /// committed content and its real deps.
  @override
  Future<PhasedValue<String>> readPhased(int phase, AssetId id) async {
    // This adapter's empty plan declares no outputs. Rust and the reader
    // decide current visibility; unknown/missing/blocked/empty contents expire
    // at this phase and must be tried again at a later phase, as before.
    final timer = resolverActionMetrics.enabled ? (Stopwatch()..start()) : null;
    final known = buildState.isSource(id);
    if (!known) buildState.addMissingSource(id);
    final readable = known && await _remoteReaderWriter.canRead(id);
    if (timer != null) {
      resolverActionMetrics.depVisibilityUs += timer.elapsedMicroseconds;
    }
    if (!readable) {
      return PhasedValue.unavailable(before: '', expiresAfter: phase);
    }
    final value = (await _contentOfForDeps(
      id,
    )).dartStringValueOrEmptyFail(id: id);
    return value.isEmpty
        ? PhasedValue.unavailable(before: '', expiresAfter: phase)
        : PhasedValue.fixed(value);
  }

  @override
  Future<bool> isReadable(
    AssetId id,
    int phase, {
    bool catchInvalidInputs = false,
  }) async {
    try {
      checkInvalidInput(id);
    } on InvalidInputException {
      if (catchInvalidInputs) return false;
      rethrow;
    } on PackageNotFoundException {
      if (catchInvalidInputs) return false;
      rethrow;
    }
    if (Placeholders.isPlaceholderPath(id.path)) return false;
    return _remoteReaderWriter.canRead(id);
  }

  @override
  Future<bool> isReadableId(AssetId id, int phase) async {
    if (Placeholders.isPlaceholderPath(id.path)) return false;
    return _remoteReaderWriter.canRead(id);
  }

  @override
  Stream<AssetId> findAssets(
    Glob glob, {
    required String package,
    required int phase,
    void Function(GlobId)? trackGlob,
  }) {
    trackGlob?.call(
      GlobId(package: package, glob: glob.pattern, phaseNumber: phase),
    );
    return _remoteReaderWriter.findAssets(glob);
  }
}
