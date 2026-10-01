import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/worker_factory_probe.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  setUp(() => temporary = Directory.systemTemp.createTempSync('worker-probe-'));
  tearDown(() => temporary.deleteSync(recursive: true));

  test(
    'isolates factory errors and preserves multi-factory options and root',
    () {
      final requests = File('${temporary.path}/requests.json');
      final output = File('${temporary.path}/result.json');
      requests.writeAsStringSync(
        jsonEncode([
          {
            'id': 'target|normal',
            'options': {
              'suffix': '.custom',
              'nested': {'value': 'original'},
            },
            'is_root': true,
            'post_process': false,
            'factories': [
              {'id': 'normal#factory0', 'name': 'first'},
              {'id': 'normal#factory1', 'name': 'second'},
            ],
          },
          {
            'id': 'target|broken',
            'options': {},
            'is_root': false,
            'post_process': false,
            'factories': [
              {'id': 'broken', 'name': 'throws'},
            ],
          },
          {
            'id': 'dependency|cleanup',
            'options': {'extension': '.part'},
            'is_root': false,
            'post_process': true,
            'factories': [
              {'id': 'cleanup', 'name': 'cleanup'},
            ],
          },
        ]),
      );
      final optionsSeen = <BuilderOptions>[];
      final calls = <String>[];
      runWorkerFactoryProbe(
        requestsPath: requests.path,
        resultPath: output.path,
        catalog: {
          'normal#factory0': (options) {
            calls.add('first');
            optionsSeen.add(options);
            (options.config['nested'] as Map)['value'] = 'modified';
            return _Builder(options.config['suffix'] as String);
          },
          'normal#factory1': (options) {
            calls.add('second');
            expect((options.config['nested'] as Map)['value'], 'original');
            optionsSeen.add(options);
            return _Builder('.second');
          },
          'broken': (_) {
            calls.add('throws');
            throw StateError('factory failed');
          },
        },
        postProcessCatalog: {
          'cleanup': (options) {
            calls.add('cleanup');
            optionsSeen.add(options);
            return _Cleanup(options.config['extension'] as String);
          },
        },
      );
      expect(calls, ['cleanup', 'throws', 'first', 'second']);
      expect(optionsSeen.map((options) => options.isRoot), [false, true, true]);
      expect(jsonDecode(output.readAsStringSync()), {
        'target|normal': [
          {
            'factory': 'first',
            'builder_type': '_Builder',
            'build_extensions': {
              '.dart': ['.custom'],
            },
          },
          {
            'factory': 'second',
            'builder_type': '_Builder',
            'build_extensions': {
              '.dart': ['.second'],
            },
          },
        ],
        'dependency|cleanup': [
          {
            'factory': 'cleanup',
            'build_extensions': {},
            'input_extensions': ['.part'],
          },
        ],
      });
    },
  );
}

class _Builder implements Builder {
  _Builder(this.suffix);
  final String suffix;
  @override
  Map<String, List<String>> get buildExtensions => {
    '.dart': [suffix],
  };
  @override
  Future<void> build(BuildStep buildStep) async {}
}

class _Cleanup implements PostProcessBuilder {
  _Cleanup(this.extension);
  final String extension;
  @override
  Iterable<String> get inputExtensions => [extension];
  @override
  Future<void> build(PostProcessBuildStep buildStep) async {}
}
