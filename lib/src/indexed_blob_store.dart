import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A single-file, append-only key/value blob store.
///
/// Layout: a sequence of
/// `[u32 keyLen][u32 valueLen][key][value][u16 fletcher16(value)]`
/// records. The first read scans the file once and builds an in-memory index
/// of `key -> (value offset, value length)`; reads after that are a single
/// `RandomAccessFile` seek+read, replacing the open/read/close-per-key cost
/// of one-file-per-key stores.
///
/// Writers serialize appends with an exclusive file lock, so a concurrent
/// reader can only ever observe a torn *tail* record — which the scanner
/// tolerates by stopping at the first malformed record. Before appending, a
/// writer re-validates the bytes appended since its own scan: complete
/// records are adopted into the index, and a torn tail (a crashed writer's
/// partial record) is truncated so it cannot shadow later entries.
/// Entries are content-addressed upstream, so a missing or corrupt record is
/// just a cache miss and the caller recomputes and re-appends it.
final class IndexedBlobStore {
  IndexedBlobStore(this._filePath);

  static const _headerLength = 8;
  static const _trailerLength = 2;
  static const _maxKeyLength = 4096;

  final String _filePath;

  /// key -> (offset of the value bytes, value length)
  Map<String, (int, int)>? _index;

  /// File offset just past the last complete record the index was built
  /// from; bytes beyond it were appended after that scan.
  int _indexedEnd = 0;

  RandomAccessFile? _raf;

  /// Total entries in the index; exposed for tests.
  int get entryCount => (_index ??= _scan()).length;

  /// Includes complete records appended by sibling processes since our scan.
  bool containsKeySuffix(String suffix) {
    final index = _index ??= _scan();
    _refreshIndex(index);
    return index.keys.any((key) => key.endsWith(suffix));
  }

  /// Refresh once at a publication boundary rather than polling on every
  /// miss. Cold analysis creates many genuinely new keys, so miss polling
  /// adds filesystem work even when there is no sibling value to reuse.
  void refresh() => _refreshIndex(_index ??= _scan());

  Uint8List? get(String key) {
    final index = _index ??= _scan();
    final slice = index[key];
    if (slice == null) return null;
    try {
      final raf = _raf ??= File(_filePath).openSync(mode: FileMode.append);
      raf.setPositionSync(slice.$1);
      final bytes = raf.readSync(slice.$2 + _trailerLength);
      if (bytes.length != slice.$2 + _trailerLength) return null;
      if (_checksumOf(bytes, slice.$2) == null) return null;
      return Uint8List.sublistView(bytes, 0, slice.$2);
    } on Object {
      return null;
    }
  }

  /// Read-only tail adoption. A reader must never truncate a writer's partial
  /// record; leave it unindexed and retry it on the next miss.
  void _refreshIndex(Map<String, (int, int)> index) {
    try {
      final file = File(_filePath);
      final length = file.lengthSync();
      if (length == _indexedEnd) return;
      if (length < _indexedEnd) {
        _raf?.closeSync();
        _raf = null;
        index
          ..clear()
          ..addAll(_scan());
        return;
      }
      final raf = _raf ??= file.openSync(mode: FileMode.append);
      raf.setPositionSync(_indexedEnd);
      final tail = raf.readSync(length - _indexedEnd);
      _indexedEnd = _parseInto(index, tail, _indexedEnd);
    } on FileSystemException {
      // A missing or unavailable cache remains a miss.
    }
  }

  /// Appends `value` under `key` unless the checksum-valid value is identical.
  /// Best-effort: any failure is swallowed so a
  /// cache write can never break the build; a later read just misses.
  /// Returns whether the value was already present or flushed successfully.
  bool put(String key, Uint8List value) {
    try {
      final index = _index ??= _scan();
      final keyBytes = utf8.encode(key);
      if (keyBytes.isEmpty || keyBytes.length > _maxKeyLength) return false;
      File(_filePath).parent.createSync(recursive: true);
      final raf = _raf ??= File(_filePath).openSync(mode: FileMode.append);
      raf.lockSync(FileLock.exclusive);
      try {
        _adoptTail(raf, index);
        // Check after adopting sibling writers' records, while holding the
        // lock. Keys alone cannot establish equality or detect corruption.
        final slice = index[key];
        if (slice != null && slice.$2 == value.length) {
          final existing = get(key);
          if (existing != null && _equalBytes(existing, value)) return true;
        }
        // Re-seek to the live end: reads or a truncation since the last write
        // may have moved the handle's position.
        raf.setPositionSync(raf.lengthSync());
        final offset = raf.lengthSync();
        final recordBytes =
            (BytesBuilder()
                  ..add(_u32(keyBytes.length))
                  ..add(_u32(value.length))
                  ..add(keyBytes)
                  ..add(value)
                  ..add(_u16(_fletcher16(value))))
                .toBytes();
        raf.writeFromSync(recordBytes);
        raf.flushSync();
        index[key] = (offset + _headerLength + keyBytes.length, value.length);
        _indexedEnd = offset + recordBytes.length;
        return true;
      } finally {
        raf.unlockSync();
      }
    } on Object {
      // Cache writes are best-effort.
      return false;
    }
  }

  /// Indexes complete records appended after [_indexedEnd] and truncates a
  /// torn tail. Runs under the write lock, so no writer is mid-append.
  void _adoptTail(RandomAccessFile raf, Map<String, (int, int)> index) {
    final length = raf.lengthSync();
    if (length <= _indexedEnd) return;
    raf.setPositionSync(_indexedEnd);
    final tail = raf.readSync(length - _indexedEnd);
    final end = _parseInto(index, tail, _indexedEnd);
    _indexedEnd = end;
    if (end < length) {
      raf.truncateSync(end);
      // An append-mode handle can hold a stale end position: re-seek so the
      // next write lands at the new end, not past the truncated gap.
      raf.setPositionSync(raf.lengthSync());
    }
  }

  /// Reads the store file once and indexes every complete record, stopping
  /// at the first malformed or truncated (concurrently appended) record.
  Map<String, (int, int)> _scan() {
    final index = <String, (int, int)>{};
    try {
      final bytes = File(_filePath).readAsBytesSync();
      _indexedEnd = _parseInto(index, bytes, 0);
    } on Object {
      _indexedEnd = 0;
      // A missing or unreadable file means an empty store.
    }
    return index;
  }

  /// Parses records in [bytes] starting at file offset [base], adding
  /// `key -> (value offset, value length)` entries, and returns the file
  /// offset just past the last complete, checksum-valid record.
  int _parseInto(Map<String, (int, int)> index, Uint8List bytes, int base) {
    var pos = 0;
    while (pos + _headerLength + _trailerLength <= bytes.length) {
      final header = ByteData.sublistView(bytes, pos, pos + _headerLength);
      final keyLen = header.getUint32(0, Endian.little);
      final valLen = header.getUint32(4, Endian.little);
      final recordLen = _headerLength + keyLen + valLen + _trailerLength;
      if (keyLen == 0 ||
          keyLen > _maxKeyLength ||
          pos + recordLen > bytes.length) {
        break;
      }
      final key = utf8.decode(
        Uint8List.sublistView(
          bytes,
          pos + _headerLength,
          pos + _headerLength + keyLen,
        ),
        allowMalformed: true,
      );
      final valStart = pos + _headerLength + keyLen;
      final stored = ByteData.sublistView(
        bytes,
        valStart + valLen,
        valStart + valLen + _trailerLength,
      ).getUint16(0, Endian.little);
      if (stored != _fletcher16(bytes, valStart, valStart + valLen)) {
        break;
      }
      index[key] = (base + pos + _headerLength + keyLen, valLen);
      pos += recordLen;
    }
    return base + pos;
  }

  void close() {
    _raf?.closeSync();
    _raf = null;
  }

  static Uint8List _u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  static bool _equalBytes(Uint8List left, Uint8List right) {
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  static Uint8List _u16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  /// The value bytes when the trailing checksum matches, else null.
  Uint8List? _checksumOf(Uint8List bytes, int valLen) {
    final stored = ByteData.sublistView(
      bytes,
      valLen,
      valLen + _trailerLength,
    ).getUint16(0, Endian.little);
    if (stored != _fletcher16(bytes, 0, valLen)) return null;
    return bytes;
  }

  /// Fletcher-16 over `[start, end)`. The mod-255 reduction is deferred to
  /// chunks of 5802 bytes — the largest block in which `c1` cannot overflow —
  /// the same technique `package:analyzer`'s file-store validator uses, since
  /// a per-byte modulo costs more than the read it guards.
  static int _fletcher16(Uint8List bytes, [int start = 0, int? end]) {
    end ??= bytes.length;
    var c0 = 0;
    var c1 = 0;
    var remaining = end - start;
    var offset = start;
    while (remaining > 0) {
      final chunk = remaining > 5802 ? 5802 : remaining;
      for (var i = 0; i < chunk; i++) {
        c0 += bytes[offset + i];
        c1 += c0;
      }
      c0 %= 255;
      c1 %= 255;
      offset += chunk;
      remaining -= chunk;
    }
    return (c1 << 8) | c0;
  }
}
