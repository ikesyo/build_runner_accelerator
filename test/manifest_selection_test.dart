import 'package:build_config/build_config.dart';
import 'package:build_runner_accelerator/src/manifest/model.dart';
import 'package:build_runner_accelerator/src/manifest/selection.dart';
import 'package:build_runner/src/build_plan/build_package.dart' as stock;
import 'package:build_runner/src/build_plan/build_packages.dart' as stock;
import 'package:build_runner/src/build_plan/builder_definition.dart' as stock;
import 'package:test/test.dart';

void main() {
  test('workspace auto-application agrees with stock dependency peers', () {
    final nodes = {
      for (final name in [
        'root',
        'a',
        'b',
        'middle',
        'shared',
        'gen_a',
        'gen_b',
      ])
        name: PackageInfo(
          name: name,
          path: '/$name',
          isRoot: ['root', 'a', 'b'].contains(name),
        ),
    };
    void depends(String name, List<String> dependencies) => nodes[name]!
        .dependencies
        .addAll(dependencies.map((name) => nodes[name]!));
    depends('root', ['shared']);
    depends('a', ['middle']);
    depends('middle', ['shared', 'gen_a']);
    depends('b', ['shared', 'gen_b']);
    final outputs = [nodes['root']!, nodes['a']!, nodes['b']!];
    final stockPackages = stock.BuildPackages.workspaceBuild(
      currentPackage: 'a',
      workspace: 'root',
      packages: [
        for (final node in nodes.values)
          stock.BuildPackage.forTesting(
            name: node.name,
            isOutput: node.isRoot,
            dependencies: node.dependencies.map((d) => d.name),
          ),
      ],
    );
    final configs = {
      for (final node in nodes.values)
        node.name: BuildConfig.fromMap(node.name, const [], {}),
    };
    final targets = [
      for (final node in nodes.values)
        TargetInfo(
          package: node,
          target:
              configs[node.name]!.buildTargets['${node.name}:${node.name}']!,
          sources: const PatternSet([], []),
        ),
    ];
    for (final mode in ['root_package', 'all_packages', 'dependents', 'none']) {
      final builderConfig = BuildConfig.fromMap('gen_a', const [], {
        'builders': {
          'producer': {
            ..._builder('create', autoApply: mode),
            'build_to': 'cache',
          },
        },
      });
      final definition = builderConfig.builderDefinitions['gen_a:producer']!;
      final selected = selectApplications(
        rootPackageName: 'root',
        rootConfig: configs['root']!,
        orderedTargets: targets,
        definitions: {'gen_a:producer': DefinitionInfo.normal(definition)},
        workspaceOutputPackages: outputs,
      );
      final stockDefinition = stock.BuilderDefinition.fromConfig(definition);
      for (final node in nodes.values) {
        expect(
          selected.containsKey('${node.name}:${node.name}|gen_a:producer'),
          stockDefinition.autoAppliesTo(
            stockPackages[node.name]!,
            restrictForWorkspacePackages: stockPackages,
          ),
          reason: '$mode on ${node.name}',
        );
      }
    }
  });

  test('source builders are visible only in workspace output packages', () {
    final root = PackageInfo(name: 'root', path: '/root', isRoot: true);
    final member = PackageInfo(name: 'member', path: '/member', isRoot: true);
    final dependency = PackageInfo(name: 'dep', path: '/dep', isRoot: false);
    final definitionConfig = BuildConfig.fromMap('gen', const [], {
      'builders': {
        'producer': {..._builder('create'), 'build_to': 'source'},
      },
    });
    final targets = [
      for (final package in [root, member, dependency])
        () {
          final config = BuildConfig.fromMap(package.name, const [], {
            'targets': {
              r'$default': {
                'builders': {
                  'gen:producer': {'enabled': true},
                },
              },
            },
          });
          return TargetInfo(
            package: package,
            target: config.buildTargets['${package.name}:${package.name}']!,
            sources: const PatternSet([], []),
          );
        }(),
    ];
    final selected = selectApplications(
      rootPackageName: 'root',
      rootConfig: BuildConfig.fromMap('root', const [], {}),
      orderedTargets: targets,
      definitions: _definitions(definitionConfig),
      workspaceOutputPackages: [root, member],
    );
    expect(
      selected.keys,
      unorderedEquals(['root:root|gen:producer', 'member:member|gen:producer']),
    );
  });

  for (final enabled in [true, false]) {
    test('shared-part flag survives selection when enabled=$enabled', () {
      final config = BuildConfig.fromMap('example', const <String>[], {
        'targets': {
          r'$default': {
            'builders': {
              'example:producer': {'enabled': enabled},
            },
          },
        },
      });
      Map<String, SelectedBuilder> select() => selectApplications(
        rootPackageName: 'example',
        rootConfig: config,
        orderedTargets: [_target(config)],
        definitions: {
          'example:producer': DefinitionInfo.normal(_LibraryBuilder()),
        },
      );
      final selected = select();
      if (enabled) {
        expect(selected.values.single.definition.addsToLibrary, isTrue);
      } else {
        expect(selected, isEmpty);
      }
    });
  }
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

// Supply the new flag even when testing against build_config 1.3.x.
class _LibraryBuilder extends BuilderDefinition {
  _LibraryBuilder()
    : super(
        builderFactories: ['createProducer'],
        buildExtensions: {
          '.dart': ['.g.dart'],
        },
        import: 'package:example/builder.dart',
        autoApply: AutoApply.rootPackage,
        buildTo: BuildTo.source,
      );

  bool get addsToLibrary => true;

  @override
  String get key => 'example:producer';
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
