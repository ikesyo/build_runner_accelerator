import 'dart:async';
import 'dart:convert';

import 'package:build_config/build_config.dart';
import 'package:build_runner_accelerator/src/manifest/model.dart';
import 'package:build_runner_accelerator/src/manifest/probe.dart';
import 'package:test/test.dart';

void main() {
  test('decodes valid mappings and ignores invalid partial results', () {
    final config = _config();
    final requests = <FactoryProbeRequest>[
      _request(config, 'valid'),
      _request(config, 'wrong_factory'),
      _request(config, 'wrong_shape'),
    ];

    final result = decodeFactoryProbeResponse(
      jsonEncode({
        'valid': [
          {
            'factory': 'createBuilder',
            'build_extensions': {
              '.dart': ['.g.dart'],
            },
          },
        ],
        'wrong_factory': [
          {
            'factory': 'otherFactory',
            'build_extensions': {
              '.dart': ['.g.dart'],
            },
          },
        ],
        'wrong_shape': <Object>[],
        'unknown': [
          {
            'factory': 'createBuilder',
            'build_extensions': <String, List<String>>{},
          },
        ],
      }),
      requests,
    );

    expect(result.keys, <String>['valid']);
    expect(result['valid']!.single.factory, 'createBuilder');
    expect(result['valid']!.single.buildExtensions, {
      '.dart': <String>['.g.dart'],
    });
  });

  test('treats invalid or non-object probe responses as unavailable', () {
    final request = _request(_config(), 'builder');

    expect(
      decodeFactoryProbeResponse('not json', <FactoryProbeRequest>[request]),
      isEmpty,
    );
    expect(
      decodeFactoryProbeResult(<Object>[], <FactoryProbeRequest>[request]),
      isEmpty,
    );
  });

  test('kills a probe that exceeds its timeout', () async {
    final exitCode = Completer<int>();
    var killed = false;

    final result = await waitForProbeExit(
      exitCode: exitCode.future,
      kill: () => killed = true,
      timeout: const Duration(milliseconds: 20),
      killGracePeriod: const Duration(milliseconds: 1),
    );

    expect(result, isNull);
    expect(killed, isTrue);
  });
}

BuildConfig _config() => BuildConfig.fromMap('example', const <String>[], {
  'builders': {
    'builder': {
      'import': 'package:example/builder.dart',
      'builder_factories': <String>['createBuilder'],
      'build_extensions': <String, List<String>>{
        '.dart': <String>['.g.dart'],
      },
    },
  },
});

FactoryProbeRequest _request(BuildConfig config, String id) =>
    FactoryProbeRequest(
      id: id,
      definition: DefinitionInfo.normal(
        config.builderDefinitions['example:builder']!,
      ),
      options: const <String, dynamic>{},
      isRoot: true,
    );
