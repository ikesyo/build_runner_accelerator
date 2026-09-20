import 'package:build_runner_accelerator/src/launcher_process.dart';
import 'package:test/test.dart';

void main() {
  test('decodes a valid release downloader response', () {
    expect(decodeReleaseDownloaderResponse('{"ok":true,"path":"frontend"}'), {
      'ok': true,
      'path': 'frontend',
    });
  });

  test('normalizes malformed release downloader output to StateError', () {
    expect(
      () => decodeReleaseDownloaderResponse('debug output\nnot json'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('debug output'), contains('not json')),
        ),
      ),
    );
  });
}
