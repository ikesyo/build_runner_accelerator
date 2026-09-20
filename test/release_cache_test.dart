import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:build_runner_accelerator/src/release_cache.dart';
import 'package:build_runner_accelerator/src/release_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('derives the platform archive filename', () {
    expect(
      ReleaseArtifactCache.archiveFilename('linux-x64'),
      'build_runner_accelerator-linux-x64.tar.gz',
    );
    expect(
      ReleaseArtifactCache.archiveFilename('windows-arm64'),
      'build_runner_accelerator-windows-arm64.zip',
    );
  });

  test('rejects path components that could escape the release cache', () {
    expect(
      () => ReleaseArtifactCache.validatePathComponent('../cache', 'target'),
      throwsA(isA<ReleaseDownloadException>()),
    );
    expect(
      () => ReleaseArtifactCache.validatePathComponent('linux/x64', 'target'),
      throwsA(isA<ReleaseDownloadException>()),
    );
  });

  test('extracts the uniquely matching binary from a zip archive', () {
    final bytes = utf8.encode('frontend');
    final archive = Archive()
      ..addFile(
        ArchiveFile('linux-x64/build_runner_accelerator', bytes.length, bytes),
      );
    final archiveBytes = ZipEncoder().encode(archive);

    expect(
      ReleaseArtifactCache.extractBinary(
        archiveBytes,
        archiveFilename: 'build_runner_accelerator-linux-x64.zip',
        binaryName: 'build_runner_accelerator',
      ),
      bytes,
    );
  });

  test('rejects an archive without exactly one matching binary', () {
    final archive = Archive()
      ..addFile(ArchiveFile('README', 1, [1]))
      ..addFile(ArchiveFile('other', 1, [2]));
    final archiveBytes = ZipEncoder().encode(archive);

    expect(
      () => ReleaseArtifactCache.extractBinary(
        archiveBytes,
        archiveFilename: 'build_runner_accelerator-linux-x64.zip',
        binaryName: 'build_runner_accelerator',
      ),
      throwsA(isA<ReleaseDownloadException>()),
    );
  });
}
