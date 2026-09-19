import 'package:build_runner_accelerator/src/release_downloader.dart';
import 'package:build_runner_accelerator/src/release_transport.dart';
import 'package:test/test.dart';

void main() {
  test('builds release URLs below the versioned release prefix', () {
    final client = ReleaseDownloadClient(
      baseUrl: 'https://mirror.example/releases',
      requireHttps: true,
      requestTimeout: const Duration(seconds: 1),
    );

    expect(
      client.releaseUri('0.3.0', 'release-manifest.json').toString(),
      'https://mirror.example/releases/v0.3.0/release-manifest.json',
    );
  });

  test('rejects non-HTTPS downloads when HTTPS is required', () {
    final client = ReleaseDownloadClient(
      baseUrl: 'https://mirror.example/releases',
      requireHttps: true,
      requestTimeout: const Duration(seconds: 1),
    );

    expect(
      () => client.download(
        Uri.parse('http://mirror.example/file'),
        maxBytes: 1024,
      ),
      throwsA(isA<ReleaseDownloadException>()),
    );
  });
}
