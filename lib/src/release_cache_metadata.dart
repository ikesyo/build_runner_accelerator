import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const releaseCacheMetadataFilename = 'artifact.json';

/// Lightweight validation for an installed release. This module intentionally
/// avoids archive and crypto imports so the normal launcher path stays small.
class ReleaseCacheMetadata {
  const ReleaseCacheMetadata._();

  static String archiveFilename(String target) {
    final extension = target.startsWith('windows-') ? '.zip' : '.tar.gz';
    return 'build_runner_accelerator-$target$extension';
  }

  static Future<String?> validBinary({
    required String cacheDirectory,
    required String version,
    required String target,
    required String binaryName,
    Future<String?> Function(String path)? digestReader,
    Future<String?> Function(String path)? fallbackDigest,
  }) async {
    final targetDirectory = Directory(p.join(cacheDirectory, version, target));
    final binary = File(p.join(targetDirectory.path, binaryName));
    final metadataFile = File(
      p.join(targetDirectory.path, releaseCacheMetadataFilename),
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
          decoded['archive'] != archiveFilename(target) ||
          decoded['archive_size'] is! int ||
          decoded['archive_size'] <= 0 ||
          decoded['archive_sha256'] is! String ||
          !_isSha256(decoded['archive_sha256'] as String) ||
          decoded['binary_sha256'] is! String ||
          !_isSha256(decoded['binary_sha256'] as String)) {
        return null;
      }
      final digest =
          await (digestReader ?? _sha256File)(binary.path) ??
          await fallbackDigest?.call(binary.path);
      if (digest == null || digest != decoded['binary_sha256']) return null;
      return binary.absolute.path;
    } on Object {
      return null;
    }
  }
}

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Future<String?> _sha256File(String path) async {
  final command = Platform.isWindows
      ? ('certutil', ['-hashfile', path, 'SHA256'])
      : Platform.isMacOS
      ? ('shasum', ['-a', '256', path])
      : ('sha256sum', [path]);
  try {
    final result = await Process.run(command.$1, command.$2);
    if (result.exitCode != 0) return null;
    final match = RegExp(
      r'\b[0-9a-fA-F]{64}\b',
    ).firstMatch(result.stdout.toString());
    return match?.group(0)?.toLowerCase();
  } on Object {
    return null;
  }
}
