import 'dart:io';
import 'dart:typed_data';

// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/byte_store.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:path/path.dart' as p;

import 'indexed_blob_store.dart';

/// Disposable v2 analyzer pack. Earlier formats are intentionally ignored.
final class PackedAnalysisByteStore implements ByteStore {
  PackedAnalysisByteStore(String dir)
    : _store = IndexedBlobStore(p.join(dir, 'store.v2.bin'));

  final IndexedBlobStore _store;

  bool get hasLinkedEntries => _store.containsKeySuffix('.linked');

  static bool hasLegacyLinkedEntries(String dir) {
    final legacy = FileByteStore(dir);
    return _findLegacyFiles(
      dir,
    ).keys.any((key) => key.endsWith('.linked') && legacy.get(key) != null);
  }

  @override
  Uint8List? get(String key) => _store.get(key);

  @override
  Uint8List putGet(String key, Uint8List bytes) {
    _store.put(key, bytes);
    return bytes;
  }

  @override
  void release(Iterable<String> keys) {}

  void close() => _store.close();

  /// Used only by the per-key opt-out store's readiness check.
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
