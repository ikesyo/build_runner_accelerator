import 'package:build_runner_accelerator/src/manifest/mapping.dart';
import 'package:build_runner_accelerator/src/manifest/model.dart';
import 'package:test/test.dart';

void main() {
  group('manifestExtensions', () {
    test('normalizes suffix outputs without changing the input mapping', () {
      final extension = manifestExtensions(<String, List<String>>{
        '.dart': <String>['g.dart'],
      })!.single;

      expect(extension.inputSuffix, '.dart');
      expect(extension.inputMatch, 'suffix');
      expect(extension.inputAnchored, isFalse);
      expect(extension.outputSuffixes, <String>['.g.dart']);
    });

    test('keeps all-asset and capture mappings explicit', () {
      final allAssets = manifestExtensions(<String, List<String>>{
        '': <String>['.g.dart'],
      })!.single;
      expect(allAssets.inputMatch, 'all');
      expect(allAssets.inputSuffix, isEmpty);
      expect(allAssets.outputSuffixes, <String>['.g.dart']);

      final capture = manifestExtensions(<String, List<String>>{
        '^lib/{{name}}.dart': <String>['lib/{{name}}.g.dart'],
      })!.single;
      expect(capture.inputMatch, 'capture');
      expect(capture.inputAnchored, isTrue);
      expect(capture.outputSuffixes, <String>['lib/{{name}}.g.dart']);
    });

    test('rejects unsupported and incomplete capture mappings', () {
      expect(
        manifestExtensions(<String, List<String>>{
          '.dart': <String>['*generated.dart'],
        }),
        isNull,
      );
      expect(
        manifestExtensions(<String, List<String>>{
          '^lib/{{name}}/{{name}}.dart': <String>['lib/{{name}}.g.dart'],
        }),
        isNull,
      );
      expect(
        manifestExtensions(<String, List<String>>{
          '^lib/{{name}}.dart': <String>['lib/generated.g.dart'],
        }),
        isNull,
      );
    });
  });

  test('serializes the normalized manifest definition fields', () {
    final definition = ManifestDefinition(
      id: 'example:builder',
      importUri: 'package:example/builder.dart',
      factory: 'builder',
      kind: 'normal',
      extensions: const <ManifestExtension>[
        ManifestExtension(
          inputSuffix: '.dart',
          inputMatch: 'suffix',
          inputAnchored: false,
          outputSuffixes: <String>['.g.dart'],
        ),
      ],
      inputExtensions: const <String>[],
      buildTo: 'source',
      outputIsOptional: false,
      isOptional: false,
      requiredInputSuffixes: const <String>[],
      triggers: const <ManifestTrigger>[],
    );

    final json = definition.toJson(
      generateFor: const <String>['lib/**'],
      generateForExclude: const <String>[],
      targetSources: const <String>['**'],
      targetSourcesExclude: const <String>[],
      options: const <String, dynamic>{},
      phase: 2,
      target: 'example:example',
      package: 'example',
      targetOrder: 1,
      excludedInputSuffixes: const <String>['.g.dart'],
    );

    expect(json['id'], 'example:builder');
    expect(json['extensions'], <Map<String, dynamic>>[
      <String, dynamic>{
        'input_suffix': '.dart',
        'input_match': 'suffix',
        'input_anchored': false,
        'output_suffixes': <String>['.g.dart'],
      },
    ]);
    expect(json['input_suffix'], '.dart');
    expect(json['output_suffixes'], <String>['.g.dart']);
    expect(json['phase'], 2);
    expect(json['target_order'], 1);
  });
}
