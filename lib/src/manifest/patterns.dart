import 'package:build_config/build_config.dart';
import 'model.dart';

// Match build_runner 2.16.2 without importing its Analyzer-backed build plan
// into the manifest generator. The stock constants are checked in tests.
const defaultRootSources = [
  'assets/**',
  'benchmark/**',
  'bin/**',
  'CHANGELOG*',
  'example/**',
  'lib/**',
  'test/**',
  'integration_test/**',
  'tool/**',
  'web/**',
  'node/**',
  'LICENSE*',
  'pubspec.yaml',
  'pubspec.lock',
  'README*',
  r'$package$',
];
const defaultDependencySources = [
  'CHANGELOG*',
  'lib/**',
  'bin/**',
  'LICENSE*',
  'pubspec.yaml',
  'README*',
];

PatternSet targetPatterns(
  BuildTarget target,
  PackageInfo package,
  BuildConfig config,
) {
  final include = target.sources.include;
  if (include == null) {
    final defaults = <String>[
      ...(package.isRoot ? defaultRootSources : defaultDependencySources),
      ...config.additionalPublicAssets,
    ];
    return _patternSet(
      defaults,
      target.sources.exclude?.toList(growable: false) ?? const [],
    );
  }
  return _patternSet(
    include.toList(growable: false),
    target.sources.exclude?.toList(growable: false) ?? const [],
  );
}

Map<String, dynamic> assetSources(
  Iterable<TargetInfo> targets,
  Map<String, BuildConfig> configs,
) {
  final result = <String, Map<String, dynamic>>{};
  for (final target in targets) {
    final package = target.package;
    final entry = result.putIfAbsent(
      package.name,
      () => <String, dynamic>{
        'targets': <Map<String, dynamic>>[],
        'public_assets': package.isRoot
            ? null
            : _patternSet([
                ...defaultDependencySources,
                ...configs[package.name]!.additionalPublicAssets,
              ], const []).include,
      },
    );
    (entry['targets'] as List<Map<String, dynamic>>).add({
      'include': target.sources.include,
      'exclude': target.sources.exclude,
    });
  }
  return result;
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
