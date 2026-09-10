import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'release downloader entrypoint accepts a direct dart invocation',
    () async {
      final entrypoint = File(
        'lib/src/release_downloader_entrypoint.dart',
      ).absolute.path;
      final result = await Process.run(Platform.resolvedExecutable, [
        '--suppress-analytics',
        'run',
        entrypoint,
      ], workingDirectory: Directory.current.path);

      expect(result.exitCode, 1);
      expect(result.stdout, contains('invalid release downloader invocation'));
    },
  );
}
