import 'package:build_config/build_config.dart';
import 'model.dart';

PatternSet targetPatterns(
  BuildTarget target,
  PackageInfo package,
  BuildConfig config,
) {
  final include = target.sources.include;
  if (include == null || include.isEmpty) {
    final defaults = package.isRoot
        ? const ['**']
        : <String>[
            'CHANGELOG*',
            'lib/**',
            'bin/**',
            'LICENSE*',
            'pubspec.yaml',
            'README*',
            ...config.additionalPublicAssets,
          ];
    return _patternSet(
      defaults,
      target.sources.exclude?.toList(growable: false) ?? const [],
    );
  }
  return patterns(target.sources);
}

PatternSet patterns(InputSet inputSet) {
  final include = inputSet.include;
  final includePatterns = include == null || include.isEmpty
      ? const ['**']
      : include.toList(growable: false);
  final excludePatterns = inputSet.exclude?.toList(growable: false) ?? const [];
  return _patternSet(includePatterns, excludePatterns);
}

PatternSet _patternSet(List<String> include, List<String> exclude) {
  if (include.any((pattern) => !_supportedPattern(pattern)) ||
      exclude.any((pattern) => !_supportedPattern(pattern))) {
    throw StateError('target sources contain an unsupported glob');
  }
  return PatternSet(include, exclude);
}

bool _supportedPattern(String pattern) =>
    pattern.isNotEmpty &&
    !pattern.contains('\\') &&
    !pattern.contains(RegExp(r'[\[\]{}!]'));
