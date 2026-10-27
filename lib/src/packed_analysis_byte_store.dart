import 'dart:typed_data';

// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:path/path.dart' as p;

import 'indexed_blob_store.dart';

/// Bounded generations of v2 analyzer packs. Single-pack caches are ignored.
final class PackedAnalysisByteStore implements ByteStore {
  PackedAnalysisByteStore(String dir)
    : _store = IndexedBlobStore(p.join(dir, 'store.v2.bin'));

  final IndexedBlobStore _store;

  bool get hasLinkedEntries => _store.containsKeySuffix('.linked');

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
}
