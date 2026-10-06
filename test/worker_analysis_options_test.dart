import 'package:analyzer/dart/analysis/features.dart';
import 'package:build_runner_accelerator/src/worker_analysis_options.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  test('package and non-package files retain the requested features', () {
    final features = FeatureSet.fromEnableFlags2(
      sdkLanguageVersion: Version(3, 11, 0),
      flags: ['enhanced-parts'],
    );
    final options = workerAnalysisOptions(features);

    expect(options.contextFeatures, same(features));
    expect(options.nonPackageFeatureSet, same(features));
    expect(options.contextFeatures.isEnabled(Feature.enhanced_parts), isTrue);
    expect(
      options.nonPackageFeatureSet.isEnabled(Feature.enhanced_parts),
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
      disabled.nonPackageFeatureSet.isEnabled(Feature.enhanced_parts),
      isFalse,
    );
    expect(enabled.contextFeatures.isEnabled(Feature.enhanced_parts), isTrue);
    expect(
      enabled.nonPackageFeatureSet.isEnabled(Feature.enhanced_parts),
      isTrue,
    );
  });
}
