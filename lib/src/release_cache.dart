import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'release_manifest.dart';
import 'release_cache_metadata.dart';

export 'release_cache_metadata.dart'
    show ReleaseCacheMetadata, releaseCacheMetadataFilename;

const defaultReleaseCacheLockTimeout = Duration(minutes: 2);
const _cacheLockRetryDelay = Duration(milliseconds: 100);

/// Owns the versioned release cache, including validation, extraction, and
/// the per-target lock used to serialize installations.
class ReleaseArtifactCache {
  ReleaseArtifactCache({
    required String cacheDirectory,
    this.lockTimeout = defaultReleaseCacheLockTimeout,
  }) : cacheDirectory = p.normalize(cacheDirectory) {
    if (lockTimeout.isNegative || lockTimeout == Duration.zero) {
      throw ArgumentError.value(
        lockTimeout,
        'lockTimeout',
        'must be greater than zero',
      );
    }
  }

  final String cacheDirectory;
  final Duration lockTimeout;

  Future<T> withTargetLock<T>({
    required String version,
    required String target,
    required Future<T> Function() action,
  }) async {
    final versionDirectory = Directory(p.join(cacheDirectory, version));
    await versionDirectory.create(recursive: true);
    final lock = await _CacheLock.acquire(
      File(p.join(versionDirectory.path, '.$target.lock')),
      timeout: lockTimeout,
    );
    try {
      return await action();
    } finally {
      await lock.release();
    }
  }

  Future<String?> validBinary({
    required String version,
    required String target,
    required String binaryName,
  }) => ReleaseCacheMetadata.validBinary(
    cacheDirectory: cacheDirectory,
    version: version,
    target: target,
    binaryName: binaryName,
  );

  Future<String> install({
    required String version,
    required String target,
    required String binaryName,
    required ReleaseArtifact artifact,
    required List<int> archiveBytes,
  }) async {
    final versionDirectory = Directory(p.join(cacheDirectory, version));
    final targetDirectory = Directory(p.join(versionDirectory.path, target));
    await targetDirectory.create(recursive: true);
    final binary = File(p.join(targetDirectory.path, binaryName));
    final metadata = File(
      p.join(targetDirectory.path, releaseCacheMetadataFilename),
    );
    final temporarySuffix = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final temporaryBinary = File(
      p.join(targetDirectory.path, '.$binaryName.$temporarySuffix.tmp'),
    );
    final temporaryMetadata = File(
      p.join(
        targetDirectory.path,
        '.$releaseCacheMetadataFilename.$temporarySuffix.tmp',
      ),
    );

    try {
      final binaryBytes = extractBinary(
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

      final installed = await validBinary(
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

  static String archiveFilename(String target) {
    return ReleaseCacheMetadata.archiveFilename(target);
  }

  static List<int> extractBinary(
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

  static void validatePathComponent(String value, String label) {
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

  static Future<_CacheLock> acquire(
    File file, {
    required Duration timeout,
  }) async {
    await file.parent.create(recursive: true);
    final elapsed = Stopwatch()..start();
    while (true) {
      final handle = await file.open(mode: FileMode.append);
      try {
        // The non-blocking lock keeps a hung process from making every later
        // installation wait forever. A successful handle remains open for the
        // entire download and installation, and the OS releases it if the
        // owning process exits.
        await handle.lock(FileLock.exclusive);
        return _CacheLock(handle);
      } on FileSystemException {
        // A failed non-blocking lock does not own the handle. Close it before
        // retrying so every attempt has an independently cancellable lock
        // operation.
        await handle.close();
      } on Object {
        await handle.close();
        rethrow;
      }

      if (elapsed.elapsed.compareTo(timeout) >= 0) {
        throw ReleaseDownloadException(
          'timed out waiting for release cache lock: ${file.path}',
        );
      }
      await Future<void>.delayed(_cacheLockRetryDelay);
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

Future<void> _makeExecutable(String path) async {
  if (Platform.isWindows) return;
  final result = await Process.run('chmod', ['755', path]);
  if (result.exitCode != 0) {
    throw ReleaseDownloadException(
      'failed to mark downloaded frontend executable: ${result.stderr}',
    );
  }
}

Future<void> _replaceFileAtomically(File temporary, File destination) async {
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
