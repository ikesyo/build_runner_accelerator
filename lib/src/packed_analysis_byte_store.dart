import 'dart:io';
import 'dart:typed_data';

// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/byte_store.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:path/path.dart' as p;

import 'indexed_blob_store.dart';

/// Packed analyzer cache with read-time migration of legacy shard files.
final class PackedAnalysisByteStore implements ByteStore {
  PackedAnalysisByteStore(String dir)
    : _store = IndexedBlobStore(p.join(dir, 'store.v1.bin')),
      _legacy = FileByteStore(dir),
      _legacyFiles = _findLegacyFiles(dir);

  final IndexedBlobStore _store;
  final FileByteStore _legacy;
  final Map<String, File> _legacyFiles;

  @override
  Uint8List? get(String key) {
    final bytes = _store.get(key);
    if (bytes != null) {
      _removeLegacy(key);
      return bytes;
    }
    final legacy = _legacy.get(key);
    if (legacy != null && _store.put(key, legacy)) _removeLegacy(key);
    return legacy;
  }

  @override
  Uint8List putGet(String key, Uint8List bytes) {
    if (_store.put(key, bytes)) _removeLegacy(key);
    return bytes;
  }

  @override
  void release(Iterable<String> keys) {}

  void close() => _store.close();

  void _removeLegacy(String key) {
    final file = _legacyFiles[key];
    if (file == null) return;
    try {
      file.deleteSync();
      _legacyFiles.remove(key);
    } on PathNotFoundException {
      // Another worker already removed this migrated entry.
      _legacyFiles.remove(key);
    } on FileSystemException {
      // Cleanup is best-effort; retain it for a later attempt.
    }
  }

  /// Snapshot shard filenames once, avoiding a legacy stat/unlink for every
  /// packed hit after migration. Ignore links, temp files and other layouts.
  static Map<String, File> _findLegacyFiles(String dir) {
    final files = <String, File>{};
    final shardPattern = RegExp(r'^[a-z0-9_]{2}$');
    final keyPattern = RegExp(r'^[a-z0-9_][a-z0-9_][a-z0-9._]{1,98}$');
    try {
      for (final entity in Directory(dir).listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final shard = p.basename(entity.path);
        if (!shardPattern.hasMatch(shard)) continue;
        try {
          for (final file in entity.listSync(followLinks: false)) {
            if (file is! File) continue;
            final key = p.basename(file.path);
            if (keyPattern.hasMatch(key) &&
                !key.contains('..') &&
                key.startsWith(shard)) {
              files[key] = file;
            }
          }
        } on FileSystemException {
          // A sibling may be removing entries; cache reads still fall back.
        }
      }
    } on FileSystemException {
      // A missing or unreadable directory is just an empty cache.
    }
    return files;
  }
}
