import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final packed in ['0', '1']) {
    test(
      'directive cache is packed despite retired PACKED_STORE=$packed',
      () async {
        final dir = Directory.systemTemp.createTempSync('asset-deps-cache-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final result = await Process.run(
          Platform.resolvedExecutable,
          [
            '--packages=${File('.dart_tool/package_config.json').absolute.path}',
            'test/asset_deps_cache_process.dart',
          ],
          environment: {
            'BUILD_RUNNER_ACCELERATOR_CACHE': dir.path,
            'BUILD_RUNNER_ACCELERATOR_DEP_CACHE': '1',
            'BUILD_RUNNER_ACCELERATOR_PACKED_STORE': packed,
          },
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final files = dir.listSync(recursive: true).whereType<File>();
        expect(
          files.where((file) => file.path.endsWith('store.bin')),
          hasLength(1),
        );
        expect(
          files.where((file) => file.path.endsWith('.json')),
          hasLength(2),
        );
      },
    );
  }
  test('DEP_CACHE=0 disables directive caching', () async {
    final dir = Directory.systemTemp.createTempSync('asset-deps-disabled-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        'test/asset_deps_cache_process.dart',
        'disabled',
      ],
      environment: {
        'BUILD_RUNNER_ACCELERATOR_CACHE': dir.path,
        'BUILD_RUNNER_ACCELERATOR_DEP_CACHE': '0',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(dir.listSync(), isEmpty);
  });

  test(
    'an unavailable packed cache is a miss and preserves the path',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'asset-deps-unavailable-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final blocked = File('${dir.path}/cache')..writeAsStringSync('keep');
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          'test/asset_deps_cache_process.dart',
          'unavailable',
        ],
        environment: {
          'BUILD_RUNNER_ACCELERATOR_CACHE': blocked.path,
          'BUILD_RUNNER_ACCELERATOR_DEP_CACHE': '1',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(blocked.readAsStringSync(), 'keep');
    },
  );
}
