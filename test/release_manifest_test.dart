import 'dart:convert';

import 'package:build_runner_accelerator/src/release_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('parses the matching artifact from a signed manifest payload', () {
    final manifest = ReleaseManifest.parse(
      utf8.encode(jsonEncode(_manifestJson())),
      expectedVersion: '0.3.0',
      expectedTarget: 'linux-x64',
      expectedArchiveFilename: 'build_runner_accelerator-linux-x64.tar.gz',
    );

    expect(manifest.packageVersion, '0.3.0');
    expect(manifest.protocolMajor, releaseProtocolMajor);
    expect(manifest.artifacts, hasLength(2));
    expect(
      manifest.artifacts
          .singleWhere((artifact) => artifact.target == 'linux-x64')
          .filename,
      'build_runner_accelerator-linux-x64.tar.gz',
    );
  });

  test('rejects a manifest with a mismatched version', () {
    expect(
      () => ReleaseManifest.parse(
        utf8.encode(jsonEncode(_manifestJson())),
        expectedVersion: '0.3.1',
        expectedTarget: 'linux-x64',
        expectedArchiveFilename: 'build_runner_accelerator-linux-x64.tar.gz',
      ),
      throwsA(
        isA<ReleaseDownloadException>().having(
          (error) => error.message,
          'message',
          contains('version mismatch'),
        ),
      ),
    );
  });

  test('rejects unsafe artifact filenames', () {
    final manifest = _manifestJson();
    (manifest['artifacts'] as List).first['filename'] = '../frontend.tar.gz';

    expect(
      () => ReleaseManifest.parse(
        utf8.encode(jsonEncode(manifest)),
        expectedVersion: '0.3.0',
        expectedTarget: 'linux-x64',
        expectedArchiveFilename: 'build_runner_accelerator-linux-x64.tar.gz',
      ),
      throwsA(
        isA<ReleaseDownloadException>().having(
          (error) => error.message,
          'message',
          contains('must be a basename'),
        ),
      ),
    );
  });

  test('rejects malformed JSON', () {
    expect(
      () => ReleaseManifest.parse(
        utf8.encode('{'),
        expectedVersion: '0.3.0',
        expectedTarget: 'linux-x64',
        expectedArchiveFilename: 'build_runner_accelerator-linux-x64.tar.gz',
      ),
      throwsA(isA<ReleaseDownloadException>()),
    );
  });
}

Map<String, dynamic> _manifestJson() => {
  'schema_version': releaseManifestSchemaVersion,
  'package_version': '0.3.0',
  'protocol_major': releaseProtocolMajor,
  'artifacts': [
    {
      'target': 'linux-x64',
      'filename': 'build_runner_accelerator-linux-x64.tar.gz',
      'size': 10,
      'sha256': _sha256,
    },
    {
      'target': 'windows-x64',
      'filename': 'build_runner_accelerator-windows-x64.zip',
      'size': 10,
      'sha256': _sha256,
    },
  ],
};

const _sha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
