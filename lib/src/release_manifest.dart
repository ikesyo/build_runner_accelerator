import 'dart:convert';

import 'package:path/path.dart' as p;

const releaseManifestSchemaVersion = 1;
const releaseProtocolMajor = 1;

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
