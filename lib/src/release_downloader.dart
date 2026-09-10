import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'release_downloader_api.dart';

export 'release_downloader_api.dart' show releaseBaseUrl;

const releaseManifestSchemaVersion = 1;
const releaseProtocolMajor = 1;

// Raw Ed25519 public key bytes, base64 encoded. The corresponding private key
// must only be stored in the release-signing secret; it is never part of the
// package or repository.
const releaseSigningPublicKeyBase64 =
    'dkdKVJxTEsabSMrzAqZL7gdf67dym17IIRhBRRSEwSo=';

const _cacheMetadataFilename = 'artifact.json';
const _maximumManifestBytes = 1024 * 1024;
const _maximumSignatureBytes = 1024;
const _maximumArtifactBytes = 128 * 1024 * 1024;

class ReleaseDownloadException implements Exception {
  ReleaseDownloadException(this.message);

  final String message;

  @override
  String toString() => 'ReleaseDownloadException: $message';
}

class ReleaseArtifact {
  ReleaseArtifact({
    required this.target,
    required this.filename,
    required this.size,
    required this.sha256,
  });

  final String target;
  final String filename;
  final int size;
  final String sha256;
}

class ReleaseManifest {
  ReleaseManifest({
    required this.packageVersion,
    required this.protocolMajor,
    required this.artifacts,
  });

  factory ReleaseManifest.parse(
    List<int> bytes, {
    required String expectedVersion,
    required String expectedTarget,
    required String expectedArchiveFilename,
  }) {
    late final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object catch (error) {
      throw ReleaseDownloadException(
        'release manifest is not valid JSON: $error',
      );
    }
    if (decoded is! Map) {
      throw ReleaseDownloadException('release manifest must be a JSON object');
    }

    final schemaVersion = decoded['schema_version'];
    if (schemaVersion != releaseManifestSchemaVersion) {
      throw ReleaseDownloadException(
        'unsupported release manifest schema: $schemaVersion',
      );
    }
    final packageVersion = decoded['package_version'];
    if (packageVersion != expectedVersion) {
      throw ReleaseDownloadException(
        'release manifest version mismatch: expected $expectedVersion, '
        'got $packageVersion',
      );
    }
    final protocolMajor = decoded['protocol_major'];
    if (protocolMajor != releaseProtocolMajor) {
      throw ReleaseDownloadException(
        'unsupported release protocol: $protocolMajor',
      );
    }

    final rawArtifacts = decoded['artifacts'];
    if (rawArtifacts is! List) {
      throw ReleaseDownloadException(
        'release manifest artifacts must be an array',
      );
    }
    final artifacts = <ReleaseArtifact>[];
    for (final rawArtifact in rawArtifacts) {
      if (rawArtifact is! Map) {
        throw ReleaseDownloadException('release artifact must be an object');
      }
      final target = rawArtifact['target'];
      final filename = rawArtifact['filename'];
      final size = rawArtifact['size'];
      final sha256 = rawArtifact['sha256'];
      if (target is! String ||
          filename is! String ||
          size is! int ||
          sha256 is! String) {
        throw ReleaseDownloadException(
          'release artifact has invalid fields: $rawArtifact',
        );
      }
      if (target.isEmpty || filename.isEmpty || size <= 0) {
        throw ReleaseDownloadException(
          'release artifact has invalid identity or size: $rawArtifact',
        );
      }
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
        throw ReleaseDownloadException(
          'release artifact has an invalid SHA-256: $sha256',
        );
      }
      if (filename.contains('/') ||
          filename.contains(r'\') ||
          filename != p.basename(filename)) {
        throw ReleaseDownloadException(
          'release artifact filename must be a basename: $filename',
        );
      }
      artifacts.add(
        ReleaseArtifact(
          target: target,
          filename: filename,
          size: size,
          sha256: sha256,
        ),
      );
    }

    final matching = artifacts
        .where((artifact) => artifact.target == expectedTarget)
        .toList(growable: false);
    if (matching.length != 1) {
      throw ReleaseDownloadException(
        'release manifest does not contain exactly one $expectedTarget '
        'artifact',
      );
    }
    final artifact = matching.single;
    if (artifact.filename != expectedArchiveFilename) {
      throw ReleaseDownloadException(
        'release artifact filename mismatch: expected '
        '$expectedArchiveFilename, got ${artifact.filename}',
      );
    }

    return ReleaseManifest(
      packageVersion: packageVersion as String,
      protocolMajor: protocolMajor as int,
      artifacts: List.unmodifiable(artifacts),
    );
  }

  final String packageVersion;
  final int protocolMajor;
  final List<ReleaseArtifact> artifacts;
}

/// Downloads and installs one versioned, signed native frontend.
class ReleaseDownloader implements ReleaseArtifactDownloader {
  ReleaseDownloader({
    required String cacheDirectory,
    this.baseUrl = releaseBaseUrl,
    List<int>? trustedPublicKey,
    HttpClient? httpClient,
    this.requireHttps = true,
    this.requestTimeout = const Duration(seconds: 30),
  }) : cacheDirectory = p.normalize(cacheDirectory),
       _httpClient = httpClient,
       trustedPublicKey = List.unmodifiable(
         trustedPublicKey ?? base64Decode(releaseSigningPublicKeyBase64),
       ) {
    if (this.trustedPublicKey.length != 32) {
      throw ArgumentError.value(
        this.trustedPublicKey.length,
        'trustedPublicKey',
        'an Ed25519 public key must contain 32 bytes',
      );
    }
    final uri = Uri.tryParse(this.baseUrl);
    if (uri == null || uri.host.isEmpty) {
      throw ArgumentError.value(this.baseUrl, 'baseUrl', 'must be an URL');
    }
    if (requireHttps && uri.scheme != 'https') {
      throw ArgumentError.value(
        this.baseUrl,
        'baseUrl',
        'must use HTTPS for release downloads',
      );
    }
  }

  final String cacheDirectory;
  final String baseUrl;
  final List<int> trustedPublicKey;
  final bool requireHttps;
  final Duration requestTimeout;
  final HttpClient? _httpClient;

  Future<String> ensureInstalled({
    required String version,
    required String target,
    required String binaryName,
  }) async {
    _validatePathComponent(version, 'version');
    _validatePathComponent(target, 'target');
    _validatePathComponent(binaryName, 'binary name');

    final versionDirectory = Directory(p.join(cacheDirectory, version));
    await versionDirectory.create(recursive: true);
    final lock = await _CacheLock.acquire(
      File(p.join(versionDirectory.path, '.$target.lock')),
    );
    try {
      final cached = await _validCachedBinary(
        version: version,
        target: target,
        binaryName: binaryName,
      );
      if (cached != null) return cached;

      final archiveFilename = _archiveFilename(target);
      final manifestBytes = await _download(
        _releaseUri(version, 'release-manifest.json'),
        maxBytes: _maximumManifestBytes,
      );
      final signatureBytes = await _download(
        _releaseUri(version, 'release-manifest.json.sig'),
        maxBytes: _maximumSignatureBytes,
      );
      await _verifyManifestSignature(manifestBytes, signatureBytes);
      final manifest = ReleaseManifest.parse(
        manifestBytes,
        expectedVersion: version,
        expectedTarget: target,
        expectedArchiveFilename: archiveFilename,
      );
      final artifact = manifest.artifacts.singleWhere(
        (candidate) => candidate.target == target,
      );

      final archiveBytes = await _download(
        _releaseUri(version, artifact.filename),
        maxBytes: _maximumArtifactBytes,
      );
      if (archiveBytes.length != artifact.size) {
        throw ReleaseDownloadException(
          'release artifact size mismatch: expected ${artifact.size}, '
          'got ${archiveBytes.length}',
        );
      }
      final archiveDigest = crypto.sha256.convert(archiveBytes).toString();
      if (archiveDigest != artifact.sha256) {
        throw ReleaseDownloadException(
          'release artifact SHA-256 mismatch: expected ${artifact.sha256}, '
          'got $archiveDigest',
        );
      }

      return await _install(
        version: version,
        target: target,
        binaryName: binaryName,
        artifact: artifact,
        archiveBytes: archiveBytes,
        versionDirectory: versionDirectory,
      );
    } finally {
      await lock.release();
    }
  }

  Future<String?> _validCachedBinary({
    required String version,
    required String target,
    required String binaryName,
  }) async {
    final targetDirectory = Directory(p.join(cacheDirectory, version, target));
    final binary = File(p.join(targetDirectory.path, binaryName));
    final metadataFile = File(
      p.join(targetDirectory.path, _cacheMetadataFilename),
    );
    if (!await binary.exists() || !await metadataFile.exists()) return null;
    if (await FileSystemEntity.type(binary.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }

    try {
      final decoded = jsonDecode(await metadataFile.readAsString());
      if (decoded is! Map ||
          decoded['schema_version'] != 1 ||
          decoded['package_version'] != version ||
          decoded['target'] != target ||
          decoded['binary'] != binaryName ||
          decoded['archive'] != _archiveFilename(target) ||
          decoded['archive_size'] is! int ||
          decoded['archive_size'] <= 0 ||
          decoded['archive_sha256'] is! String ||
          !RegExp(
            r'^[0-9a-f]{64}$',
          ).hasMatch(decoded['archive_sha256'] as String) ||
          decoded['binary_sha256'] is! String ||
          !RegExp(
            r'^[0-9a-f]{64}$',
          ).hasMatch(decoded['binary_sha256'] as String)) {
        return null;
      }
      final digest = crypto.sha256
          .convert(await binary.readAsBytes())
          .toString();
      if (digest != decoded['binary_sha256']) return null;
      return binary.absolute.path;
    } on Object {
      return null;
    }
  }

  Future<String> _install({
    required String version,
    required String target,
    required String binaryName,
    required ReleaseArtifact artifact,
    required List<int> archiveBytes,
    required Directory versionDirectory,
  }) async {
    final targetDirectory = Directory(p.join(versionDirectory.path, target));
    await targetDirectory.create(recursive: true);
    final binary = File(p.join(targetDirectory.path, binaryName));
    final metadata = File(p.join(targetDirectory.path, _cacheMetadataFilename));
    final temporarySuffix = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final temporaryBinary = File(
      p.join(targetDirectory.path, '.$binaryName.$temporarySuffix.tmp'),
    );
    final temporaryMetadata = File(
      p.join(
        targetDirectory.path,
        '.$_cacheMetadataFilename.$temporarySuffix.tmp',
      ),
    );

    try {
      final binaryBytes = _extractBinary(
        archiveBytes,
        archiveFilename: artifact.filename,
        binaryName: binaryName,
      );
      await temporaryBinary.writeAsBytes(binaryBytes, flush: true);
      await _makeExecutable(temporaryBinary.path);
      await _replaceFileAtomically(temporaryBinary, binary);

      final binaryDigest = crypto.sha256.convert(binaryBytes).toString();
      final metadataJson = {
        'schema_version': 1,
        'package_version': version,
        'target': target,
        'binary': binaryName,
        'archive': artifact.filename,
        'archive_size': artifact.size,
        'archive_sha256': artifact.sha256,
        'binary_sha256': binaryDigest,
      };
      await temporaryMetadata.writeAsString(
        '${jsonEncode(metadataJson)}\n',
        flush: true,
      );
      await _replaceFileAtomically(temporaryMetadata, metadata);

      final installed = await _validCachedBinary(
        version: version,
        target: target,
        binaryName: binaryName,
      );
      if (installed == null) {
        throw ReleaseDownloadException(
          'installed release artifact failed cache validation',
        );
      }
      return installed;
    } finally {
      if (await temporaryBinary.exists()) await temporaryBinary.delete();
      if (await temporaryMetadata.exists()) await temporaryMetadata.delete();
    }
  }

  Future<void> _verifyManifestSignature(
    List<int> manifestBytes,
    List<int> signatureBytes,
  ) async {
    if (signatureBytes.length != 64) {
      throw ReleaseDownloadException(
        'release manifest signature must contain 64 bytes',
      );
    }
    final algorithm = Ed25519();
    final publicKey = SimplePublicKey(
      trustedPublicKey,
      type: KeyPairType.ed25519,
    );
    final valid = await algorithm.verify(
      manifestBytes,
      signature: Signature(signatureBytes, publicKey: publicKey),
    );
    if (!valid) {
      throw ReleaseDownloadException('release manifest signature is invalid');
    }
  }

  Future<List<int>> _download(Uri uri, {required int maxBytes}) async {
    if (requireHttps && uri.scheme != 'https') {
      throw ReleaseDownloadException('refusing non-HTTPS download: $uri');
    }
    final client = _httpClient ?? HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(requestTimeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'build_runner_accelerator',
      );
      final response = await request.close().timeout(requestTimeout);
      for (final redirect in response.redirects) {
        if (requireHttps && redirect.location.scheme != 'https') {
          throw ReleaseDownloadException(
            'refusing non-HTTPS release redirect: ${redirect.location}',
          );
        }
      }
      if (response.statusCode != HttpStatus.ok) {
        throw ReleaseDownloadException(
          'release download failed with HTTP ${response.statusCode}: $uri',
        );
      }
      if (response.contentLength > maxBytes) {
        throw ReleaseDownloadException(
          'release response is too large: ${response.contentLength} bytes',
        );
      }

      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.timeout(requestTimeout)) {
        length += chunk.length;
        if (length > maxBytes) {
          throw ReleaseDownloadException(
            'release response exceeded $maxBytes bytes',
          );
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } on ReleaseDownloadException {
      rethrow;
    } on TimeoutException {
      throw ReleaseDownloadException('release download timed out: $uri');
    } on Object catch (error) {
      throw ReleaseDownloadException(
        'release download failed for $uri: $error',
      );
    } finally {
      if (_httpClient == null) client.close(force: true);
    }
  }

  Uri _releaseUri(String version, String filename) {
    final base = Uri.parse(baseUrl);
    final segments = <String>[
      ...base.pathSegments.where((segment) => segment.isNotEmpty),
      'v$version',
      filename,
    ];
    return base.replace(
      path: '/${segments.map(Uri.encodeComponent).join('/')}',
    );
  }

  static List<int> _extractBinary(
    List<int> archiveBytes, {
    required String archiveFilename,
    required String binaryName,
  }) {
    late final Archive archive;
    try {
      archive = archiveFilename.endsWith('.zip')
          ? ZipDecoder().decodeBytes(archiveBytes)
          : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(archiveBytes));
    } on ReleaseDownloadException {
      rethrow;
    } on Object catch (error) {
      throw ReleaseDownloadException(
        'release archive could not be decoded: $error',
      );
    }
    final candidates = archive
        .where((file) {
          if (!file.isFile) return false;
          final name = file.name.replaceAll('\\', '/');
          if (name.startsWith('/') || name.split('/').contains('..')) {
            throw ReleaseDownloadException(
              'release archive contains an unsafe path: ${file.name}',
            );
          }
          return p.posix.basename(name) == binaryName;
        })
        .toList(growable: false);
    if (candidates.length != 1) {
      throw ReleaseDownloadException(
        'release archive must contain exactly one $binaryName file',
      );
    }
    return List<int>.from(candidates.single.content);
  }

  static Future<void> _makeExecutable(String path) async {
    if (Platform.isWindows) return;
    final result = await Process.run('chmod', ['755', path]);
    if (result.exitCode != 0) {
      throw ReleaseDownloadException(
        'failed to mark downloaded frontend executable: ${result.stderr}',
      );
    }
  }

  static Future<void> _replaceFileAtomically(
    File temporary,
    File destination,
  ) async {
    try {
      await temporary.rename(destination.path);
    } on FileSystemException {
      if (!await destination.exists()) rethrow;
      // Windows does not replace an existing file with rename(). The
      // destination is inside our private versioned cache, so replacing only
      // that exact cache entry is safe and keeps partial downloads invisible.
      await destination.delete();
      await temporary.rename(destination.path);
    }
  }

  static String _archiveFilename(String target) {
    final extension = target.startsWith('windows-') ? '.zip' : '.tar.gz';
    return 'build_runner_accelerator-$target$extension';
  }

  static void _validatePathComponent(String value, String label) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains(r'\')) {
      throw ReleaseDownloadException('invalid $label: $value');
    }
  }
}

class _CacheLock {
  _CacheLock(this._handle);

  final RandomAccessFile _handle;

  static Future<_CacheLock> acquire(File file) async {
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.append);
    try {
      // The OS owns the lock while this handle is open. A blocking lock lets
      // healthy installs wait for the full download and installation, while
      // the OS releases it automatically if the owning process exits.
      await handle.lock(FileLock.blockingExclusive);
      return _CacheLock(handle);
    } on Object {
      await handle.close();
      rethrow;
    }
  }

  Future<void> release() async {
    try {
      await _handle.unlock();
    } finally {
      await _handle.close();
    }
  }
}
