import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

enum _LeaseState { live, inactive, unknown }

/// Disposable bounded generations. Ordinary lookups use only the leased pack;
/// coordination and reclamation happen on open, explicit refresh and rollover.
final class IndexedBlobStore {
  IndexedBlobStore(
    this._filePath, {
    this.maxDataBytes = 256 * 1024 * 1024,
    this.maxJournalBytes = 8 * 1024 * 1024,
    this.maxRecords = 65536,
  });

  final String _filePath;
  final int maxDataBytes;
  final int maxJournalBytes;
  final int maxRecords;
  String get _root => '$_filePath.generations';
  static final _liveLeases = <String>{};
  bool _openAttempted = false;
  IndexedBlobPack? _pack;
  RandomAccessFile? _lease;
  String? _leasePath;
  String? _name;

  int get entryCount {
    _ensureOpen();
    return _pack?.entryCount ?? 0;
  }

  Uint8List? get(String key) {
    _ensureOpen();
    return _pack?.get(key);
  }

  bool containsKeySuffix(String suffix) {
    _coordinate(_followCurrent);
    // The pack performs the journal refresh itself at this boundary.
    return _pack?.containsKeySuffix(suffix) ?? false;
  }

  void refresh() {
    _coordinate(_followCurrent);
    // The lease protects these handles even if another process owns control.
    // Do not lose same-generation publications when pointer following is busy.
    _pack?.refresh();
  }

  bool put(String key, Uint8List value) {
    if (value.length + 10 > maxDataBytes || maxRecords < 1) return false;
    if (_pack == null) {
      _openAttempted = true;
      _coordinate(_followCurrent);
    }
    final pack = _pack;
    if (pack == null) return false;
    if (pack.put(key, value)) return true;
    if (!pack.needsRotation) return false;
    // Check the encoded key only on rollover, keeping ordinary puts at one
    // key encoding. Oversized entries must not churn generations on retries.
    final keyLength = utf8.encode(key).length;
    if (keyLength + value.length + 10 > maxDataBytes ||
        keyLength + 36 > maxJournalBytes)
      return false;
    var stored = false;
    _coordinate(() {
      _followCurrent();
      if (_pack!.put(key, value)) {
        stored = true;
        return;
      }
      if (!_pack!.needsRotation) return;
      // Retry reclamation before allocating another generation. A filesystem
      // that cannot reclaim inactive packs must not accumulate them forever.
      if (!_reclaim()) return;
      final recent = _pack!._recentRecords(
        excluding: key,
        reserveDataBytes: keyLength + value.length + 10,
        reserveJournalBytes: keyLength + 36,
      );
      final name = _randomName();
      _attach(name);
      // Seed bounded recent values before the requested value, preserving
      // their relative write order. Budgets reserve room for that request.
      _pack!._seed(recent.reversed);
      // A kill before pointer publication leaves only a reclaimable orphan.
      if (!_pack!.put(key, value)) {
        close();
        _reclaim();
        return;
      }
      _publish(name);
      stored = true;
      _reclaim();
    });
    return stored;
  }

  void _ensureOpen() {
    if (_pack == null && !_openAttempted) {
      _openAttempted = true;
      _coordinate(_followCurrent);
    }
  }

  /// The control inode is permanent and never renamed or deleted. Only this
  /// lock protects the small current pointer and lease creation/reclamation;
  /// each pack retains its own stable data-file writer lock.
  void _coordinate(void Function() action) {
    RandomAccessFile? control;
    var locked = false;
    try {
      Directory(_root).createSync(recursive: true);
      control = File('$_root/control').openSync(mode: FileMode.append);
      control.lockSync(FileLock.exclusive);
      locked = true;
      action();
    } on Object {
      // Cache and maintenance failures never fail a build. Latch failed opens
      // even when a failed publication closed a newly attached generation.
      if (_pack == null) _openAttempted = true;
    } finally {
      if (locked) {
        try {
          control!.unlockSync();
        } on Object {
          /* Best effort. */
        }
      }
      try {
        control?.closeSync();
      } on Object {
        /* Best effort. */
      }
    }
  }

  String? _current() {
    try {
      final file = File('$_root/current');
      if (file.lengthSync() != 36) return null;
      final bytes = file.readAsBytesSync();
      if (bytes.length != 36 ||
          ByteData.sublistView(bytes).getUint32(32, Endian.little) !=
              IndexedBlobPack._crc32(Uint8List.sublistView(bytes, 0, 32))) {
        return null;
      }
      final name = ascii.decode(bytes.sublist(0, 32));
      return RegExp(r'^[0-9a-f]{32}$').hasMatch(name) ? name : null;
    } on Object {
      return null;
    }
  }

  void _publish(String name) {
    final bytes = Uint8List(36)..setRange(0, 32, ascii.encode(name));
    ByteData.sublistView(bytes).setUint32(
      32,
      IndexedBlobPack._crc32(Uint8List.sublistView(bytes, 0, 32)),
      Endian.little,
    );
    // Readers hold control while reading. A torn pointer is a cache loss,
    // never a reason to infer ownership from directory names or reuse offsets.
    try {
      File('$_root/current').writeAsBytesSync(bytes);
    } on Object {
      // Never keep accepting local writes into an unpublished generation.
      close();
      rethrow;
    }
  }

  void _followCurrent() {
    final current = _current();
    if (current != null) {
      if (_name != current) {
        _attach(current);
        _reclaim();
      }
      return;
    }
    if (!_reclaim()) return;
    final name = _randomName();
    _attach(name);
    _publish(name);
  }

  void _attach(String name) {
    final directory = Directory('$_root/$name')..createSync();
    // Worker shutdown may release an OS lock without running close(). Prune
    // those lease files even when no generation rollover has occurred.
    if (!_pruneLeases(directory)) {
      throw FileSystemException(
        'Cannot safely prune cache leases',
        directory.path,
      );
    }
    final leasePath = '${directory.path}/lease-$pid-${_randomName()}';
    final lease = File(leasePath).openSync(mode: FileMode.append);
    try {
      lease.lockSync(FileLock.exclusive);
    } on Object {
      try {
        lease.closeSync();
      } on Object {
        /* Best effort. */
      }
      try {
        File(leasePath).deleteSync();
      } on Object {
        /* An unknown own-PID lease conservatively blocks allocation. */
      }
      rethrow;
    }
    _liveLeases.add(p.normalize(p.absolute(leasePath)));
    final pack = IndexedBlobPack(
      '${directory.path}/data',
      maxDataBytes: maxDataBytes,
      maxJournalBytes: maxJournalBytes,
      maxRecords: maxRecords,
    );
    // Close payload handles before releasing the old lease. Another process
    // can reclaim immediately after that release, including on Windows.
    close();
    _name = name;
    _leasePath = leasePath;
    _lease = lease;
    _pack = pack;
  }

  /// Under control, no new leases can appear. Never even open a lease bearing
  /// our PID: POSIX record locks are process-scoped and closing such a handle
  /// could release another instance's lock. Own-process stale leases are kept
  /// conservatively; another process can reclaim them after this process exits.
  bool _reclaim() {
    var reclaimed = true;
    final current = _current();
    for (final entity in Directory(_root).listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is! Directory ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(name) ||
          name == current ||
          name == _name)
        continue;
      var live = false;
      try {
        for (final leaseFile in entity.listSync(followLinks: false)) {
          final leaseName = p.basename(leaseFile.path);
          if (!leaseName.startsWith('lease-')) continue;
          final state = _leaseState(leaseFile.path);
          if (state == _LeaseState.unknown) reclaimed = false;
          if (state != _LeaseState.inactive) live = true;
        }
        if (!live) entity.deleteSync(recursive: true);
      } on Object {
        reclaimed = false;
      }
    }
    return reclaimed;
  }

  _LeaseState _leaseState(String path) {
    final name = p.basename(path);
    if (name.startsWith('lease-$pid-')) {
      return _liveLeases.contains(p.normalize(p.absolute(path)))
          ? _LeaseState.live
          : _LeaseState.unknown;
    }
    RandomAccessFile? lease;
    var state = _LeaseState.unknown;
    try {
      lease = File(path).openSync(mode: FileMode.append);
      lease.lockSync(FileLock.exclusive);
      lease.unlockSync();
      state = _LeaseState.inactive;
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (lease != null &&
          (code == 11 || code == 13 || code == 33 || code == 35)) {
        state = _LeaseState.live;
      }
    } on Object {
      // Unknown ownership/access failures retain files and stop allocation.
    } finally {
      try {
        lease?.closeSync();
      } on Object {
        state = _LeaseState.unknown;
      }
    }
    return state;
  }

  bool _pruneLeases(Directory directory) {
    for (final entity in directory.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!name.startsWith('lease-')) continue;
      switch (_leaseState(entity.path)) {
        case _LeaseState.unknown:
          return false;
        case _LeaseState.inactive:
          try {
            File(entity.path).deleteSync();
          } on PathNotFoundException {
            // The owner can remove its released lease outside control.
          }
        case _LeaseState.live:
          break;
      }
    }
    return true;
  }

  void close() {
    _pack?.close();
    _pack = null;
    try {
      _lease?.closeSync();
    } on Object {
      /* Best effort. */
    }
    _lease = null;
    if (_leasePath != null) {
      _liveLeases.remove(p.normalize(p.absolute(_leasePath!)));
    }
    try {
      if (_leasePath != null) File(_leasePath!).deleteSync();
    } on Object {
      /* A stale lease is safely reclaimed by a later process. */
    }
    _leasePath = null;
    _name = null;
    _openAttempted = false;
  }

  static String _randomName() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

/// Append-only data pack with a separate, checksummed publication journal.
/// Startup reads only metadata; values are verified when used. The data file
/// is the stable writer lock. A writer writes data before publishing metadata,
/// and removes incomplete journal/data tails under that lock. Lost metadata
/// loses cache entries, never requires reconstructing disposable payloads.
final class IndexedBlobPack {
  IndexedBlobPack(
    this._filePath, {
    this.maxDataBytes = 256 * 1024 * 1024,
    this.maxJournalBytes = 8 * 1024 * 1024,
    this.maxRecords = 65536,
  });

  /// Admission budgets per pack, not a machine-wide cache quota. Named
  /// arguments allow small deterministic tests; callers use fixed defaults.
  final int maxDataBytes;
  final int maxJournalBytes;
  final int maxRecords;
  bool needsRotation = false;
  int _records = 0;
  bool _capacityExceeded = false;

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
      if (length == _indexedEnd || _capacityExceeded) return;
      journal.setPositionSync(_indexedEnd);
      _indexedEnd = _parseInto(
        index,
        journal.readSync(min(length, maxJournalBytes) - _indexedEnd),
        _indexedEnd,
      );
      if (length > maxJournalBytes) _capacityExceeded = true;
      // An unread suffix may update an earlier key. Returning the prefix's
      // older value would not be a valid bounded snapshot of this journal.
      if (_capacityExceeded) index.clear();
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
    _records = 0;
    _capacityExceeded = false;
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
    needsRotation = false;
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
        if (offset == null) {
          needsRotation = true;
          return false;
        }
        // Check after adopting sibling writers' records, while holding the
        // lock. Keys alone cannot establish equality or detect corruption.
        final slice = index[key];
        if (slice != null && slice.$2 == value.length) {
          final existing = get(key);
          if (existing != null && _equalBytes(existing, value)) return true;
        }
        final recordLength =
            _headerLength + keyBytes.length + value.length + _trailerLength;
        final entryLength = _indexHeaderLength + keyBytes.length + 4;
        if (_records >= maxRecords ||
            offset + recordLength > maxDataBytes ||
            _indexedEnd + entryLength > maxJournalBytes) {
          needsRotation = true;
          return false;
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
        _records++;
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
  int? _adoptTail(
    RandomAccessFile raf,
    RandomAccessFile journal,
    Map<String, (int, int)> index,
  ) {
    _refreshIndex(index);
    final journalLength = journal.lengthSync();
    final length = raf.lengthSync();
    // A bounded scan is not a torn tail. Never repair away valid history
    // merely because this process declined to index it.
    if (_capacityExceeded || length > maxDataBytes) return null;
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
      if (_records >= maxRecords) {
        _capacityExceeded = true;
        break;
      }
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
      if (offset + _headerLength + keyLen + valLen + _trailerLength >
          maxDataBytes) {
        _capacityExceeded = true;
        break;
      }
      _records++;
      index[key] = (offset + _headerLength + keyLen, valLen);
      _dataEnd = offset + _headerLength + keyLen + valLen + _trailerLength;
      pos = end + 4;
    }
    return base + pos;
  }

  /// Seed a new unpublished generation under control with validated records.
  /// Write one data batch before its ordinary journal entries, under one data
  /// lock. The requested normal put adopts it or repairs a partial batch.
  void _seed(Iterable<(String, Uint8List)> values) {
    if (values.isEmpty) return;
    try {
      final raf = _raf ??= _openForWrite();
      raf.lockSync(FileLock.exclusive);
      try {
        final journal = _journal ??= File(
          _indexPath,
        ).openSync(mode: FileMode.append);
        if (raf.lengthSync() != 0 || journal.lengthSync() != 0) return;
        final data = BytesBuilder(copy: false);
        final entries = BytesBuilder(copy: false);
        var records = 0;
        for (final (key, record) in values) {
          final keyBytes = utf8.encode(key);
          final recordLength = record.length;
          final valueLength = ByteData.sublistView(
            record,
          ).getUint32(4, Endian.little);
          final entryLength = _indexHeaderLength + keyBytes.length + 4;
          if (keyBytes.isEmpty ||
              keyBytes.length > _maxKeyLength ||
              records >= maxRecords ||
              data.length + recordLength > maxDataBytes ||
              _journalHeaderLength + entries.length + entryLength >
                  maxJournalBytes)
            break;
          final metadata = ByteData(_indexHeaderLength)
            ..setUint32(0, keyBytes.length, Endian.little)
            ..setUint32(4, valueLength, Endian.little)
            ..setUint64(8, data.length, Endian.little);
          final entry =
              (BytesBuilder(copy: false)
                    ..add(metadata.buffer.asUint8List())
                    ..add(keyBytes))
                  .takeBytes();
          data.add(record);
          entries
            ..add(entry)
            ..add(_u32(_crc32(entry)));
          records++;
        }
        // Publish metadata only after every seed payload has been written.
        raf.writeFromSync(data.takeBytes());
        _writeGeneration(journal);
        journal.writeFromSync(entries.takeBytes());
      } finally {
        raf.unlockSync();
      }
    } on Object {
      // The requested put still retries through the ordinary tail repair.
    }
  }

  /// Seed only a small recent write window at rollover. No read tracking or
  /// second index is needed on the lookup path. Sort latest offsets because
  /// updating an existing key does not move its position in Dart's map.
  /// Payloads are checksum-validated, and all seed bytes/records count against
  /// the replacement's ordinary budgets. Reserve the incoming record first.
  List<(String, Uint8List)> _recentRecords({
    required String excluding,
    required int reserveDataBytes,
    required int reserveJournalBytes,
  }) {
    final count = min(4096, maxRecords ~/ 16);
    var remaining = min(
      min(8 * 1024 * 1024, maxDataBytes ~/ 32),
      maxDataBytes - reserveDataBytes,
    );
    var journalRemaining = min(
      maxJournalBytes ~/ 8,
      maxJournalBytes - reserveJournalBytes,
    );
    if (count == 0 || remaining <= 0 || journalRemaining <= 0) return const [];
    final entries = (_index ??= _scan()).entries.toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    final result = <(String, Uint8List)>[];
    for (final entry in entries.take(count)) {
      if (entry.key == excluding) continue;
      final keyLength = utf8.encode(entry.key).length;
      final recordLength = 10 + keyLength + entry.value.$2;
      final metadataLength = 20 + keyLength;
      if (recordLength > remaining || metadataLength > journalRemaining)
        continue;
      final value = get(entry.key);
      if (value == null) continue;
      // get() verified this exact header, key, length and checksum. The
      // payload record contains no offsets, so relocation preserves its bytes.
      final record = Uint8List.view(
        value.buffer,
        value.offsetInBytes - _headerLength - keyLength,
        recordLength,
      );
      result.add((entry.key, record));
      remaining -= recordLength;
      journalRemaining -= metadataLength;
    }
    return result;
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
