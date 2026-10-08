import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:build_config/build_config.dart';
import 'package:build_runner/src/build_plan/build_triggers.dart';
import 'package:build_runner_accelerator/src/manifest/trigger_worker.dart';
import 'package:build_runner_accelerator/src/manifest/probe.dart'
    show decodeManifestTriggers;
import 'package:built_collection/built_collection.dart';
import 'package:test/test.dart';

void main() {
  BuildConfig config(Map<String, Object> triggers) => BuildConfig(
    packageName: 'sample',
    buildTargets: {},
    triggersByBuilder: triggers,
  );

  test('preserves official digest and cross-package trigger union', () {
    final configs = {
      'root': config({
        'sample:builder': [
          'import sample/annotation.dart',
          'annotation Marker',
        ],
      }),
      'dependency': config({
        'sample:builder': ['annotation Marker', 'annotation Additional'],
        'sample:other': ['import sample/other.dart'],
      }),
    };
    final result = manifestTriggerData(configs);
    expect(
      result['digest'],
      BuildTriggers.fromConfigs(BuiltMap.from(configs)).digest.toString(),
    );
    expect(result['triggers'], {
      'sample:builder': [
        {'kind': 'annotation', 'value': 'Additional'},
        {'kind': 'annotation', 'value': 'Marker'},
        {'kind': 'import', 'value': 'sample/annotation.dart'},
      ],
      'sample:other': [
        {'kind': 'import', 'value': 'sample/other.dart'},
      ],
    });
  });

  test('empty trigger digest matches stock build_runner', () {
    expect(manifestTriggerData({'root': config({})}), {
      'digest': '99914b932bd37a50b983c5e7c90ae93b',
      'triggers': {},
    });
  });

  test('official warnings still reject unsupported configuration', () {
    for (final triggers in <Map<String, Object>>[
      {
        'invalid': ['annotation Valid'],
      },
      {
        'sample:builder': ['unknown trigger'],
      },
      {
        'sample:builder': ['import INVALID'],
      },
      {'sample:builder': 'annotation Valid'},
    ]) {
      expect(
        () => manifestTriggerData({'root': config(triggers)}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'diagnostics',
            contains('Unsupported build trigger configuration'),
          ),
        ),
      );
    }
  });

  test('helper writes structured diagnostics before nonzero exit', () async {
    final root = await Directory.systemTemp.createTemp('trigger-error-test-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/pubspec.yaml').writeAsString('name: sample\n');
    await Directory('${root.path}/.dart_tool').create();
    await File('${root.path}/.dart_tool/package_config.json').writeAsString(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'sample', 'rootUri': root.uri.toString()},
        ],
      }),
    );
    await File(
      '${root.path}/build.yaml',
    ).writeAsString('triggers:\n  sample:builder:\n    - unknown trigger\n');
    final helper = await Isolate.resolvePackageUri(
      Uri.parse(
        'package:build_runner_accelerator/src/manifest/trigger_worker.dart',
      ),
    );
    final result = File('${root.path}/result.json');
    final process = await Process.run(Platform.resolvedExecutable, [
      '--packages=${File('.dart_tool/package_config.json').absolute.path}',
      helper!.toFilePath(),
      root.path,
      result.path,
    ]);
    expect(process.exitCode, 1);
    final response = await result.readAsString();
    final error = (jsonDecode(response) as Map)['error'] as Map;
    expect(error['kind'], 'unsupported-trigger-configuration');
    expect(
      error['message'],
      startsWith('Unsupported build trigger configuration:'),
    );
    expect(process.stderr, isEmpty);
    expect(
      () => decodeManifestTriggers(response),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          error['message'],
        ),
      ),
    );
  });

  test('non-string list entries follow the official parser behavior', () {
    final result = manifestTriggerData({
      'root': config({
        'sample:builder': [null, 12, 'annotation Marker'],
      }),
    });
    expect(result['triggers'], {
      'sample:builder': [
        {'kind': 'annotation', 'value': 'Marker'},
      ],
    });
  });
}
