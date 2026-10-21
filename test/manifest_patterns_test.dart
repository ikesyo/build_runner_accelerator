import 'package:build/build.dart';
import 'package:build_config/build_config.dart';
import 'package:build_runner/src/build_plan/build_configs.dart';
import 'package:build_runner/src/build_plan/input_matcher.dart';
import 'package:build_runner_accelerator/src/manifest/model.dart';
import 'package:build_runner_accelerator/src/manifest/patterns.dart';
import 'package:glob/glob.dart';
import 'package:test/test.dart';

void main() {
  test('source defaults match the supported stock version', () {
    expect(defaultRootSources, defaultInBuildPackageSources);
    expect(defaultDependencySources, defaultDependencyVisibleAssets);
  });
  test('action target scope preserves stock virtual-primary matching', () {
    final package = PackageInfo(name: 'dep', path: '.', isRoot: false);
    for (final yaml in [
      '',
      'targets: {\$default: {sources: []}}',
      'targets: {\$default: {sources: [lib/**]}}',
      'targets: {\$default: {sources: {exclude: ["\$package\$"]}}}',
    ]) {
      final config = BuildConfig.parse('dep', [], yaml);
      final target = config.buildTargets.values.single;
      final action = patterns(target.sources);
      final stock = InputMatcher(target.sources);
      for (final path in [
        r'$package$',
        r'lib/$lib$',
        r'web/$web$',
        'lib/a.dart',
        'web/a.dart',
      ]) {
        final actual =
            action.include.any((p) => Glob(p).matches(path)) &&
            !action.exclude.any((p) => Glob(p).matches(path));
        expect(
          actual,
          stock.matches(AssetId('dep', path)),
          reason: '$yaml: $path',
        );
      }
      // Collection defaults remain distinct: no physical package placeholder
      // is admitted just because a virtual action can be planned for it.
      final physical = targetPatterns(target, package, config);
      expect(
        physical.include.any((p) => Glob(p).matches(r'$package$')),
        isFalse,
      );
    }
  });
  test(
    'default sources include public additions without admitting arbitrary paths',
    () {
      final package = PackageInfo(name: 'app', path: '.', isRoot: true);
      final config = BuildConfig.parse('app', [], '''
additional_public_assets: [shared/**]
''');
      final sources = targetPatterns(
        config.buildTargets.values.single,
        package,
        config,
      );
      expect(sources.include, containsAll(['lib/**', 'test/**', 'shared/**']));
      expect(sources.include, isNot(contains('**')));
    },
  );

  test(
    'explicit empty sources remain empty and builder-free targets are retained',
    () {
      final package = PackageInfo(name: 'app', path: '.', isRoot: true);
      final config = BuildConfig.parse('app', [], '''
targets:
  \$default:
    sources: []
  other:
    sources: [shared/**]
''');
      final targets = [
        for (final target in config.buildTargets.values)
          TargetInfo(
            package: package,
            target: target,
            sources: targetPatterns(target, package, config),
          ),
      ];
      expect(targets.first.sources.include, isEmpty);
      final encoded = assetSources(targets, {'app': config});
      expect(encoded['app']['targets'], hasLength(2));
      expect(encoded['app']['targets'][1]['include'], ['shared/**']);
    },
  );
}
