import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:build_runner_accelerator/src/release_cache.dart';
import 'package:build_runner_accelerator/src/release_manifest.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

const _sha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

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

  test(
    'uses a crypto fallback when the platform hash tool is unavailable',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'build-runner-accelerator-cache-metadata-test-',
      );
      addTearDown(() => cache.delete(recursive: true));

      const version = '0.3.0';
      const target = 'linux-x64';
      const binaryName = 'build_runner_accelerator';
      final targetDirectory = Directory('${cache.path}/$version/$target');
      await targetDirectory.create(recursive: true);
      final binary = File('${targetDirectory.path}/$binaryName');
      final bytes = utf8.encode('frontend');
      await binary.writeAsBytes(bytes);
      final binaryDigest = crypto.sha256.convert(bytes).toString();
      await File('${targetDirectory.path}/artifact.json').writeAsString(
        jsonEncode({
          'schema_version': 1,
          'package_version': version,
          'target': target,
          'binary': binaryName,
          'archive': 'build_runner_accelerator-linux-x64.tar.gz',
          'archive_size': 1,
          'archive_sha256': _sha256,
          'binary_sha256': binaryDigest,
        }),
      );

      final cached = await ReleaseCacheMetadata.validBinary(
        cacheDirectory: cache.path,
        version: version,
        target: target,
        binaryName: binaryName,
        digestReader: (_) async => null,
        fallbackDigest: (_) async => binaryDigest,
      );
      expect(cached, binary.absolute.path);

      final invalid = await ReleaseCacheMetadata.validBinary(
        cacheDirectory: cache.path,
        version: version,
        target: target,
        binaryName: binaryName,
        digestReader: (_) async => List.filled(64, 'f').join(),
        fallbackDigest: (_) async => binaryDigest,
      );
      expect(invalid, isNull);
    },
  );

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
