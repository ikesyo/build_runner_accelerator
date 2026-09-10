import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

import 'package:build_runner_accelerator/src/release_downloader.dart';

const _testVersion = '0.1.0-dev.1';
const _windowsArchiveFilename = 'build_runner_accelerator-windows-x64.zip';
const _linuxArchiveFilename = 'build_runner_accelerator-linux-x64.tar.gz';

void main() {
  late Directory cacheDirectory;
  late HttpServer server;
  late Map<String, List<int>> responses;
  late int requestCount;

  setUp(() async {
    cacheDirectory = await Directory.systemTemp.createTemp(
      'build-runner-accelerator-release-test-',
    );
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final binaryBytes = utf8.encode('native frontend test binary\n');
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'windows-x64/build_runner_accelerator.exe',
          binaryBytes.length,
          binaryBytes,
        ),
      );
    final archiveBytes = ZipEncoder().encode(archive);
    final linuxArchive = Archive()
      ..addFile(
        ArchiveFile(
          'linux-x64/build_runner_accelerator',
          binaryBytes.length,
          binaryBytes,
        ),
      );
    final linuxArchiveBytes = GZipEncoder().encode(
      TarEncoder().encode(linuxArchive),
    );
    final manifest = jsonEncode({
      'schema_version': releaseManifestSchemaVersion,
      'package_version': _testVersion,
      'protocol_major': releaseProtocolMajor,
      'artifacts': [
        {
          'target': 'windows-x64',
          'filename': _windowsArchiveFilename,
          'size': archiveBytes.length,
          'sha256': _sha256(archiveBytes),
        },
        {
          'target': 'linux-x64',
          'filename': _linuxArchiveFilename,
          'size': linuxArchiveBytes.length,
          'sha256': _sha256(linuxArchiveBytes),
        },
      ],
    });
    final manifestBytes = utf8.encode('$manifest\n');
    final signature = await algorithm.sign(manifestBytes, keyPair: keyPair);

    responses = {
      _releasePath('release-manifest.json'): manifestBytes,
      _releasePath('release-manifest.json.sig'): signature.bytes,
      _releasePath(_windowsArchiveFilename): archiveBytes,
      _releasePath(_linuxArchiveFilename): linuxArchiveBytes,
    };
    requestCount = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requestCount++;
      final body = responses[request.uri.path];
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.add(body);
      }
      await request.response.close();
    });

    _fixturePublicKey = publicKey.bytes;
  });

  tearDown(() async {
    await server.close(force: true);
    await cacheDirectory.delete(recursive: true);
  });

  test(
    'verifies, extracts, atomically installs, and reuses a cached archive',
    () async {
      final downloader = _downloader(cacheDirectory, server);
      final path = await downloader.ensureInstalled(
        version: _testVersion,
        target: 'windows-x64',
        binaryName: 'build_runner_accelerator.exe',
      );

      expect(await File(path).readAsString(), 'native frontend test binary\n');
      expect(
        await File('${Directory(path).parent.path}/artifact.json').exists(),
        isTrue,
      );
      expect(requestCount, 3);

      final cachedPath = await downloader.ensureInstalled(
        version: _testVersion,
        target: 'windows-x64',
        binaryName: 'build_runner_accelerator.exe',
      );
      expect(cachedPath, path);
      expect(requestCount, 3);
    },
  );

  test('rejects a modified manifest signature', () async {
    responses[_releasePath('release-manifest.json.sig')] = List<int>.from(
      responses[_releasePath('release-manifest.json.sig')]!,
    )..[0] ^= 1;

    expect(
      () => _downloader(cacheDirectory, server).ensureInstalled(
        version: _testVersion,
        target: 'windows-x64',
        binaryName: 'build_runner_accelerator.exe',
      ),
      throwsA(isA<ReleaseDownloadException>()),
    );
    expect(
      await File(
        '${cacheDirectory.path}/$_testVersion/windows-x64/'
        'build_runner_accelerator.exe',
      ).exists(),
      isFalse,
    );
  });

  test('extracts the tar.gz format used by Linux releases', () async {
    final path = await _downloader(cacheDirectory, server).ensureInstalled(
      version: _testVersion,
      target: 'linux-x64',
      binaryName: 'build_runner_accelerator',
    );

    expect(await File(path).readAsString(), 'native frontend test binary\n');
  });

  test(
    'rejects an artifact whose bytes do not match the signed manifest',
    () async {
      responses[_releasePath(_windowsArchiveFilename)] = List<int>.from(
        responses[_releasePath(_windowsArchiveFilename)]!,
      )..[0] ^= 1;

      expect(
        () => _downloader(cacheDirectory, server).ensureInstalled(
          version: _testVersion,
          target: 'windows-x64',
          binaryName: 'build_runner_accelerator.exe',
        ),
        throwsA(isA<ReleaseDownloadException>()),
      );
    },
  );
}

List<int> _fixturePublicKey = const [];

ReleaseDownloader _downloader(Directory cacheDirectory, HttpServer server) =>
    ReleaseDownloader(
      cacheDirectory: cacheDirectory.path,
      baseUrl: 'http://${server.address.host}:${server.port}',
      trustedPublicKey: _fixturePublicKey,
      requireHttps: false,
    );

String _sha256(List<int> bytes) {
  return crypto.sha256.convert(bytes).toString();
}

String _releasePath(String filename) => '/v$_testVersion/$filename';
