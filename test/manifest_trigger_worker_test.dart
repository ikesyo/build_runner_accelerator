import 'package:build_config/build_config.dart';
import 'package:build_runner/src/build_plan/build_triggers.dart';
import 'package:build_runner_accelerator/src/manifest/trigger_worker.dart';
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

  test('empty trigger digest stays compatible with existing manifests', () {
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
