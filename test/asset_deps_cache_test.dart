import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final packed in ['0', '1']) {
    test('digest keys persist with PACKED_STORE=$packed', () async {
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
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(dir.listSync(recursive: true).whereType<File>(), isNotEmpty);
    });
  }
}
