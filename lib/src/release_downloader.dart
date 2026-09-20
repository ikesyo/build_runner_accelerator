import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'release_cache.dart';
import 'release_downloader_api.dart';
import 'release_manifest.dart';
import 'release_transport.dart';

export 'release_cache.dart'
    show
        ReleaseArtifactCache,
        defaultReleaseCacheLockTimeout,
        releaseCacheMetadataFilename;
export 'release_downloader_api.dart'
    show ReleaseArtifactDownloader, releaseBaseUrl;
export 'release_manifest.dart'
    show
        ReleaseArtifact,
        ReleaseDownloadException,
        ReleaseManifest,
        releaseManifestSchemaVersion,
        releaseProtocolMajor;

// Raw Ed25519 public key bytes, base64 encoded. The corresponding private key
// must only be stored in the release-signing secret; it is never part of the
// package or repository.
const releaseSigningPublicKeyBase64 =
    'jJKM2jIQ5fKEw22YHJvQOPhQ139IpfbFtSQ3FMPu2ic=';

const _maximumManifestBytes = 1024 * 1024;
const _maximumSignatureBytes = 1024;
const _maximumArtifactBytes = 128 * 1024 * 1024;

/// Downloads and installs one versioned, signed native frontend.
class ReleaseDownloader implements ReleaseArtifactDownloader {
  ReleaseDownloader({
    required String cacheDirectory,
    this.baseUrl = releaseBaseUrl,
    List<int>? trustedPublicKey,
    HttpClient? httpClient,
    this.requireHttps = true,
    this.requestTimeout = const Duration(seconds: 30),
    this.cacheLockTimeout = defaultReleaseCacheLockTimeout,
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
    if (cacheLockTimeout.isNegative || cacheLockTimeout == Duration.zero) {
      throw ArgumentError.value(
        cacheLockTimeout,
        'cacheLockTimeout',
        'must be greater than zero',
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
  final Duration cacheLockTimeout;
  final HttpClient? _httpClient;

  Future<String> ensureInstalled({
    required String version,
    required String target,
    required String binaryName,
  }) async {
    ReleaseArtifactCache.validatePathComponent(version, 'version');
    ReleaseArtifactCache.validatePathComponent(target, 'target');
    ReleaseArtifactCache.validatePathComponent(binaryName, 'binary name');

    final cache = ReleaseArtifactCache(
      cacheDirectory: cacheDirectory,
      lockTimeout: cacheLockTimeout,
    );
    final client = ReleaseDownloadClient(
      baseUrl: baseUrl,
      requireHttps: requireHttps,
      requestTimeout: requestTimeout,
      httpClient: _httpClient,
    );
    return cache.withTargetLock(
      version: version,
      target: target,
      action: () async {
        final cached = await cache.validBinary(
          version: version,
          target: target,
          binaryName: binaryName,
        );
        if (cached != null) return cached;

        final archiveFilename = ReleaseArtifactCache.archiveFilename(target);
        final manifestBytes = await client.download(
          client.releaseUri(version, 'release-manifest.json'),
          maxBytes: _maximumManifestBytes,
        );
        final signatureBytes = await client.download(
          client.releaseUri(version, 'release-manifest.json.sig'),
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

        final archiveBytes = await client.download(
          client.releaseUri(version, artifact.filename),
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

        return cache.install(
          version: version,
          target: target,
          binaryName: binaryName,
          artifact: artifact,
          archiveBytes: archiveBytes,
        );
      },
    );
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
}
