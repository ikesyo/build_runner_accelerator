import 'package:build_config/build_config.dart';
import 'package:build_runner_accelerator/src/manifest/model.dart';
import 'package:build_runner_accelerator/src/manifest/selection.dart';
import 'package:test/test.dart';

void main() {
  test('selects auto-applied builders and terminates applies cycles', () {
    final config = BuildConfig.fromMap('example', const <String>[], {
      'builders': {
        'producer': _builder(
          'createProducer',
          autoApply: 'root_package',
          appliesBuilders: <String>['example:consumer'],
        ),
        'consumer': _builder(
          'createConsumer',
          appliesBuilders: <String>['example:producer'],
        ),
      },
      'targets': {
        r'$default': {'auto_apply_builders': true},
      },
    });

    final selected = selectApplications(
      rootPackageName: 'example',
      rootConfig: config,
      orderedTargets: <TargetInfo>[_target(config)],
      definitions: _definitions(config),
    );

    expect(
      selected.keys,
      unorderedEquals(<String>[
        'example:example|example:producer',
        'example:example|example:consumer',
      ]),
    );
  });

  test('honors explicit disable before auto-apply', () {
    final config = BuildConfig.fromMap('example', const <String>[], {
      'builders': {
        'producer': _builder(
          'createProducer',
          autoApply: 'root_package',
          appliesBuilders: <String>['example:consumer'],
        ),
        'consumer': _builder('createConsumer'),
      },
      'targets': {
        r'$default': {
          'builders': {
            'example:producer': {'enabled': false},
          },
        },
      },
    });

    final selected = selectApplications(
      rootPackageName: 'example',
      rootConfig: config,
      orderedTargets: <TargetInfo>[_target(config)],
      definitions: _definitions(config),
    );

    expect(selected, isEmpty);
  });

  test('honors explicit disable before selecting an applied builder', () {
    final config = BuildConfig.fromMap('example', const <String>[], {
      'builders': {
        'producer': _builder(
          'createProducer',
          appliesBuilders: <String>['example:consumer'],
        ),
        'consumer': _builder('createConsumer'),
      },
      'targets': {
        r'$default': {
          'builders': {
            'example:producer': {'enabled': true},
            'example:consumer': {'enabled': false},
          },
        },
      },
    });

    final selected = selectApplications(
      rootPackageName: 'example',
      rootConfig: config,
      orderedTargets: <TargetInfo>[_target(config)],
      definitions: _definitions(config),
    );

    expect(
      selected.keys,
      unorderedEquals(<String>['example:example|example:producer']),
    );
  });

  test('merges default, target, and global options in precedence order', () {
    final config = BuildConfig.fromMap('example', const <String>[], {
      'builders': {
        'producer': _builder(
          'createProducer',
          defaults: {
            'options': {'shared': 'default', 'default_only': true},
            'dev_options': {'mode': 'default', 'default_dev_only': true},
          },
        ),
      },
      'global_options': {
        'example:producer': {
          'options': {'shared': 'global', 'global_only': true},
          'dev_options': {'mode': 'global'},
        },
      },
      'targets': {
        r'$default': {
          'builders': {
            'example:producer': {
              'options': {'shared': 'target', 'target_only': true},
              'dev_options': {'mode': 'target'},
            },
          },
        },
      },
    });

    final selected = selectApplications(
      rootPackageName: 'example',
      rootConfig: config,
      orderedTargets: <TargetInfo>[_target(config)],
      definitions: _definitions(config),
    );

    expect(
      selected['example:example|example:producer']!.options,
      <String, dynamic>{
        'shared': 'global',
        'default_only': true,
        'mode': 'global',
        'default_dev_only': true,
        'target_only': true,
        'global_only': true,
      },
    );
  });
}

Map<String, dynamic> _builder(
  String factory, {
  String autoApply = 'none',
  List<String> appliesBuilders = const <String>[],
  Map<String, dynamic>? defaults,
}) => <String, dynamic>{
  'import': 'package:example/builder.dart',
  'builder_factories': <String>[factory],
  'build_extensions': <String, List<String>>{
    '.dart': <String>['.$factory.dart'],
  },
  'auto_apply': autoApply,
  'applies_builders': appliesBuilders,
  if (defaults != null) 'defaults': defaults,
};

Map<String, DefinitionInfo> _definitions(BuildConfig config) => {
  for (final entry in config.builderDefinitions.entries)
    entry.key: DefinitionInfo.normal(entry.value),
};

TargetInfo _target(BuildConfig config) => TargetInfo(
  package: PackageInfo(name: 'example', path: '.', isRoot: true),
  target: config.buildTargets['example:example']!,
  sources: const PatternSet(<String>[], <String>[]),
);
