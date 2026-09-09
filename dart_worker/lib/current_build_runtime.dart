import 'package:build/build.dart';
import 'package:built_collection/built_collection.dart';
import 'package:build_runner/src/build/builder_filesystem.dart'
    show BuilderFilesystem;
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
import 'package:glob/glob.dart';
import 'package:package_config/package_config.dart';

import 'remote_build_step.dart';

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
class RemoteBuildState extends BuildState {
  RemoteBuildState(this._packages, {required int phaseCount})
    : super(buildStepPlan: _emptyBuildStepPlan(phaseCount), sources: const {});

  final Set<String> _packages;

  @override
  bool isSource(AssetId id) => _packages.contains(id.package);

  @override
  bool isKnownAsset(AssetId id) => isSource(id);

  // Missing remote assets are not sticky: a later Rust phase may make the same
  // AssetId available through the overlay.
  @override
  bool isMissingSource(AssetId id) => false;
}

/// Adapts current build_runner's visibility and Analyzer filesystem hooks to
/// the Rust-backed ReaderWriter. The empty plan is intentional: Rust plans
/// declared outputs and phase visibility, while [RemoteAssetReaderWriter]
/// enforces the current action's blocked-output set.
class RemoteBuilderFilesystem extends BuilderFilesystem {
  RemoteBuilderFilesystem({
    required BuildPackages buildPackages,
    required RemoteBuildState buildState,
    required RemoteAssetReaderWriter readerWriter,
  }) : _remoteReaderWriter = readerWriter,
       super(
         buildPackages: buildPackages,
         // The Rust planner supplies the action graph; this intentionally
         // empty config is only the current BuilderFilesystem adapter.
         // ignore: invalid_use_of_visible_for_testing_member
         buildConfigs: BuildConfigs.empty(),
         buildState: buildState,
         readerWriter: readerWriter,
         assetBuilder: (_) async {},
         globEvaluator: (_) async {},
       );

  final RemoteAssetReaderWriter _remoteReaderWriter;

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
    if (!buildState.isKnownAsset(id)) return false;
    return _remoteReaderWriter.canRead(
      id,
      inArtifactTree: buildState.isInArtifactTree(id),
    );
  }

  @override
  Future<bool> isReadableId(AssetId id, int phase) async {
    if (Placeholders.isPlaceholderPath(id.path)) return false;
    return _remoteReaderWriter.canRead(
      id,
      inArtifactTree: buildState.isInArtifactTree(id),
    );
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
