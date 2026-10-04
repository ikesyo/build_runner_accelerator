import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Append-only data pack with a separate, checksummed publication journal.
/// Startup reads only metadata; values are verified when used. The data file
/// is the stable writer lock. A writer writes data before publishing metadata,
/// and removes incomplete journal/data tails under that lock. Lost metadata
/// loses cache entries, never requires reconstructing disposable payloads.
final class IndexedBlobStore {
  IndexedBlobStore(this._filePath);

  static const _headerLength = 8;
  static const _trailerLength = 2;
  static const _maxKeyLength = 4096;
  static const _indexHeaderLength = 16;
  static const _journalHeaderLength = 16;
  static const _magic = 0x32494253;
  int? _generation;
  int _dataEnd = 0;
  RandomAccessFile? _journal;
  String get _indexPath => '$_filePath.index';

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
    return index.keys.any((key) => key.endsWith(suffix) && get(key) != null);
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
      // Bind the offset to the requested key as well as checking the value.
      // This also makes stale offsets safe after recovery reuses a data tail.
      final keyBytes = utf8.encode(key);
      final recordStart = slice.$1 - _headerLength - keyBytes.length;
      if (recordStart < 0) return null;
      raf.setPositionSync(recordStart);
      final recordLength =
          _headerLength + keyBytes.length + slice.$2 + _trailerLength;
      final record = raf.readSync(recordLength);
      if (record.length != recordLength) return null;
      final header = ByteData.sublistView(record);
      if (header.getUint32(0, Endian.little) != keyBytes.length ||
          header.getUint32(4, Endian.little) != slice.$2)
        return null;
      for (var i = 0; i < keyBytes.length; i++) {
        if (record[_headerLength + i] != keyBytes[i]) return null;
      }
      final valueStart = _headerLength + keyBytes.length;
      final valueEnd = valueStart + slice.$2;
      if (header.getUint16(valueEnd, Endian.little) !=
          _fletcher16(record, valueStart, valueEnd))
        return null;
      return Uint8List.sublistView(record, valueStart, valueEnd);
    } on Object {
      return null;
    }
  }

  /// Read-only tail adoption. A reader must never truncate a writer's partial
  /// record; leave it unindexed and retry it on the next refresh.
  /// Completed prefixes are immutable: writer recovery truncates only the
  /// invalid tail, which a reader has never included in [_indexedEnd].
  void _refreshIndex(Map<String, (int, int)> index) {
    try {
      final journal = _journal ??= File(
        _indexPath,
      ).openSync(mode: FileMode.append);
      final length = journal.lengthSync();
      journal.setPositionSync(0);
      final bytes = journal.readSync(_journalHeaderLength);
      if (bytes.length != _journalHeaderLength) {
        _reset(index);
        return;
      }
      final header = ByteData.sublistView(bytes);
      if (header.getUint32(0, Endian.little) != _magic ||
          header.getUint32(12, Endian.little) !=
              _crc32(Uint8List.sublistView(bytes, 0, 12))) {
        _reset(index);
        return;
      }
      final generation = header.getUint64(4, Endian.little);
      if (_generation != generation || length < _indexedEnd) {
        _reset(index);
        _generation = generation;
        _indexedEnd = _journalHeaderLength;
      }
      if (length == _indexedEnd) return;
      journal.setPositionSync(_indexedEnd);
      _indexedEnd = _parseInto(
        index,
        journal.readSync(length - _indexedEnd),
        _indexedEnd,
      );
    } on Object {
      _reset(index);
      // Cache failure is a miss. Readers never repair a concurrent writer.
    }
  }

  void _reset(Map<String, (int, int)> index) {
    index.clear();
    _indexedEnd = 0;
    _dataEnd = 0;
    _generation = null;
  }

  void _writeGeneration(RandomAccessFile journal) {
    final random = Random.secure();
    _generation = (random.nextInt(1 << 31) << 32) | random.nextInt(1 << 32);
    final header = ByteData(_journalHeaderLength)
      ..setUint32(0, _magic, Endian.little)
      ..setUint64(4, _generation!, Endian.little);
    header.setUint32(
      12,
      _crc32(Uint8List.sublistView(header.buffer.asUint8List(), 0, 12)),
      Endian.little,
    );
    journal.setPositionSync(0);
    journal.writeFromSync(header.buffer.asUint8List());
  }

  /// Appends `value` under `key` unless the checksum-valid value is identical.
  /// Best-effort: any failure is swallowed so a
  /// cache write can never break the build; a later read just misses.
  /// Returns whether the value was already present or written successfully.
  /// Records are immediately visible to sibling readers, but are not fsynced:
  /// losing cache entries after a machine crash only requires recomputation.
  bool put(String key, Uint8List value) {
    try {
      final index = _index ??= _scan();
      final keyBytes = utf8.encode(key);
      if (keyBytes.isEmpty || keyBytes.length > _maxKeyLength) return false;
      final raf = _raf ??= _openForWrite();
      raf.lockSync(FileLock.exclusive);
      try {
        final journal = _journal ??= File(
          _indexPath,
        ).openSync(mode: FileMode.append);
        final offset = _adoptTail(raf, journal, index);
        // Check after adopting sibling writers' records, while holding the
        // lock. Keys alone cannot establish equality or detect corruption.
        final slice = index[key];
        if (slice != null && slice.$2 == value.length) {
          final existing = get(key);
          if (existing != null && _equalBytes(existing, value)) return true;
        }
        // Re-seek to the live end: reads or a truncation since the last write
        // may have moved the handle's position.
        raf.setPositionSync(offset);
        final recordBytes =
            (BytesBuilder()
                  ..add(_u32(keyBytes.length))
                  ..add(_u32(value.length))
                  ..add(keyBytes)
                  ..add(value)
                  ..add(_u16(_fletcher16(value))))
                .toBytes();
        raf.writeFromSync(recordBytes);
        // The journal is the publication boundary. No fsync is needed for
        // disposable cache bytes; synchronous writes publish to other workers.
        final metadata = ByteData(_indexHeaderLength)
          ..setUint32(0, keyBytes.length, Endian.little)
          ..setUint32(4, value.length, Endian.little)
          ..setUint64(8, offset, Endian.little);
        final entry =
            (BytesBuilder()
                  ..add(metadata.buffer.asUint8List())
                  ..add(keyBytes))
                .toBytes();
        journal.setPositionSync(_indexedEnd);
        journal.writeFromSync(
          (BytesBuilder()
                ..add(entry)
                ..add(_u32(_crc32(entry))))
              .toBytes(),
        );
        index[key] = (offset + _headerLength + keyBytes.length, value.length);
        _indexedEnd += entry.length + 4;
        _dataEnd = offset + recordBytes.length;
        return true;
      } finally {
        raf.unlockSync();
      }
    } on Object {
      // Cache writes are best-effort.
      return false;
    }
  }

  RandomAccessFile _openForWrite() {
    final file = File(_filePath);
    file.parent.createSync(recursive: true);
    return file.openSync(mode: FileMode.append);
  }

  /// Repair only while holding the data lock. Unpublished data is discarded;
  /// published values are checked lazily, so corruption cannot hide later keys.
  int _adoptTail(
    RandomAccessFile raf,
    RandomAccessFile journal,
    Map<String, (int, int)> index,
  ) {
    _refreshIndex(index);
    final journalLength = journal.lengthSync();
    final length = raf.lengthSync();
    if (length < _dataEnd) _reset(index);
    final repair = _generation == null || journalLength != _indexedEnd;
    if (repair) {
      journal.truncateSync(_indexedEnd);
      _writeGeneration(journal);
      if (_indexedEnd == 0) _indexedEnd = _journalHeaderLength;
    }
    if (length != _dataEnd) raf.truncateSync(_dataEnd);
    return _dataEnd;
  }

  Map<String, (int, int)> _scan() {
    final index = <String, (int, int)>{};
    _reset(index);
    _refreshIndex(index);
    return index;
  }

  /// Journal entry: [u32 keyLen][u32 valueLen][u64 recordOffset][key]
  /// [u32 CRC32(header + key)]. Offsets must be contiguous. Never read values.
  int _parseInto(Map<String, (int, int)> index, Uint8List bytes, int base) {
    var pos = 0;
    while (pos + _indexHeaderLength + 4 <= bytes.length) {
      final header = ByteData.sublistView(bytes, pos, pos + _indexHeaderLength);
      final keyLen = header.getUint32(0, Endian.little);
      final valLen = header.getUint32(4, Endian.little);
      final offset = header.getUint64(8, Endian.little);
      final end = pos + _indexHeaderLength + keyLen;
      if (keyLen == 0 ||
          keyLen > _maxKeyLength ||
          end + 4 > bytes.length ||
          offset != _dataEnd)
        break;
      if (ByteData.sublistView(
            bytes,
            end,
            end + 4,
          ).getUint32(0, Endian.little) !=
          _crc32(Uint8List.sublistView(bytes, pos, end)))
        break;
      final String key;
      try {
        key = utf8.decode(
          Uint8List.sublistView(bytes, pos + _indexHeaderLength, end),
        );
      } on FormatException {
        break;
      }
      index[key] = (offset + _headerLength + keyLen, valLen);
      _dataEnd = offset + _headerLength + keyLen + valLen + _trailerLength;
      pos = end + 4;
    }
    return base + pos;
  }

  static final _crcTable = List<int>.generate(256, (i) {
    var crc = i;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
    return crc;
  });

  static int _crc32(Uint8List bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc = (crc >> 8) ^ _crcTable[(crc ^ byte) & 255];
    }
    return crc ^ 0xffffffff;
  }

  void close() {
    try {
      _raf?.closeSync();
    } on Object {
      /* Best effort. */
    }
    try {
      _journal?.closeSync();
    } on Object {
      /* Best effort. */
    }
    _raf = null;
    _journal = null;
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
