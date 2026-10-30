import 'package:analyzer/dart/analysis/features.dart';
// ignore: implementation_imports
import 'package:analyzer/src/clients/build_resolvers/build_resolvers.dart'
    show AnalysisOptionsImpl, ExperimentStatus;
// AnalysisOptionsBuilder is not exported by build_resolvers in analyzer 13.3.
// engine keeps its export stable across the analysis_options file move.
// ignore: implementation_imports
import 'package:analyzer/src/generated/engine.dart' show AnalysisOptionsBuilder;

/// Creates identical feature configuration for worker and prewarm analysis.
AnalysisOptionsImpl workerAnalysisOptions(FeatureSet features) {
  final builder = AnalysisOptionsBuilder()
    ..contextFeatures = features as ExperimentStatus;
  try {
    // Older builders need both fields. Analyzer 14.7 removed this field and
    // uses contextFeatures for files outside packages as well.
    (builder as dynamic).nonPackageFeatureSet = features;
  } on NoSuchMethodError {
    // contextFeatures above is the sole feature set on Analyzer 14.7+.
  }
  return builder.build();
}
