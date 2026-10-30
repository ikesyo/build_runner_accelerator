import 'package:analyzer/dart/analysis/features.dart';
// ignore: implementation_imports
import 'package:analyzer/src/clients/build_resolvers/build_resolvers.dart'
    show AnalysisOptionsImpl;
import 'package:build_runner_accelerator/src/worker_analysis_options.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

FeatureSet nonPackageFeatures(AnalysisOptionsImpl options) {
  try {
    return (options as dynamic).nonPackageFeatureSet as FeatureSet;
  } on NoSuchMethodError {
    // Analyzer 14.7 uses contextFeatures for both package and non-package files.
    return options.contextFeatures;
  }
}

void main() {
  test('package and non-package files retain the requested features', () {
    final features = FeatureSet.fromEnableFlags2(
      sdkLanguageVersion: Version(3, 11, 0),
      flags: ['enhanced-parts'],
    );
    final options = workerAnalysisOptions(features);

    expect(options.contextFeatures, same(features));
    expect(nonPackageFeatures(options), same(features));
    expect(options.contextFeatures.isEnabled(Feature.enhanced_parts), isTrue);
    expect(
      nonPackageFeatures(options).isEnabled(Feature.enhanced_parts),
      isTrue,
    );
  });

  test('separate analyses do not share experiment configuration', () {
    final enabled = workerAnalysisOptions(
      FeatureSet.fromEnableFlags2(
        sdkLanguageVersion: Version(3, 11, 0),
        flags: ['enhanced-parts'],
      ),
    );
    final disabled = workerAnalysisOptions(
      FeatureSet.fromEnableFlags2(
        sdkLanguageVersion: Version(3, 11, 0),
        flags: [],
      ),
    );

    expect(disabled.contextFeatures.isEnabled(Feature.enhanced_parts), isFalse);
    expect(
      nonPackageFeatures(disabled).isEnabled(Feature.enhanced_parts),
      isFalse,
    );
    expect(enabled.contextFeatures.isEnabled(Feature.enhanced_parts), isTrue);
    expect(
      nonPackageFeatures(enabled).isEnabled(Feature.enhanced_parts),
      isTrue,
    );
  });
}
