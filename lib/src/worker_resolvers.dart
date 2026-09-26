// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analyzer/dart/analysis/features.dart';
// ignore: implementation_imports
import 'package:analyzer/src/clients/build_resolvers/build_resolvers.dart';
import 'package:build/build.dart';
import 'package:build/experiments.dart';
import 'package:package_config/package_config.dart';
import 'package:pool/pool.dart';

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
import 'worker_analysis_driver_model.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/build_resolver.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/build_step_resolver.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/sdk_summary.dart';

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

  /// State supporting the analysis driver.
  WorkerAnalysisDriverModel _analysisDriverModel;

  /// Specifies the language version for each package during analysis.
  PackageConfig? _packageConfig;

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
  }) => WorkerResolversImpl(
    packageConfig: packageConfig,
    analysisDriverModel: analysisDriverModel ?? WorkerAnalysisDriverModel(),
  );

  WorkerResolversImpl({
    PackageConfig? packageConfig,
    required WorkerAnalysisDriverModel analysisDriverModel,
  }) : _packageConfig = packageConfig,
       _analysisDriverModel = analysisDriverModel;

  @override
  Future<BuildStepResolver> get(BuildStep buildStep) async {
    await _initializationPool.withResource(() async {
      if (_buildResolver != null) return;
      _warnOnLanguageVersionMismatch();
      final loadedConfig = _packageConfig ??= await loadPackageConfigUri(
        Uri.parse(buildProcessState.packageConfigUri),
      );
      final driver = analysisDriver(
        _analysisDriverModel,
        AnalysisOptionsImpl()
          // ignore: deprecated_member_use
          ..contextFeatures = _featureSet(
            enableExperiments: enabledExperiments,
          ),
        await defaultSdkSummaryGenerator(),
        loadedConfig,
      );

      _buildResolver = BuildResolver(driver, _driverPool, _analysisDriverModel);
    });

    return BuildStepResolver(_buildResolver!, buildStep as BuildStepImpl);
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
