import 'dart:io';
import 'dart:typed_data';
import 'package:build/build.dart';

/// Reads and validates an immutable reset snapshot without retaining the file.
Map<AssetId, Uint8List> readOverlayBlob(
  Map<String, Object?> metadata,
  Set<AssetId> updated,
) {
  final path = metadata['path'];
  final length = metadata['length'];
  final index = metadata['index'];
  if (path is! String || length is! int || index is! Map<String, Object?>) {
    throw const FormatException('Invalid overlay blob metadata');
  }
  if (length < 0 || !File(path).isAbsolute) {
    throw const FormatException('Invalid overlay blob length/path');
  }
  final entries = <AssetId, (int, int)>{};
  var end = 0;
  for (final entry in index.entries) {
    final range = entry.value;
    if (range is! Map<String, Object?>) {
      throw const FormatException('Invalid overlay blob index');
    }
    final id = AssetId.parse(entry.key);
    final offset = range['offset'];
    final size = range['length'];
    if (!updated.contains(id) ||
        offset is! int ||
        size is! int ||
        offset != end ||
        size < 0 ||
        offset < 0 ||
        offset > length ||
        size > length - offset) {
      throw const FormatException('Invalid overlay blob range');
    }
    end = offset + size;
    entries[id] = (offset, size);
  }
  if (end != length)
    throw const FormatException('Incomplete overlay blob index');
  final file = File(path).openSync();
  try {
    if (file.lengthSync() != length) {
      throw const FormatException('Incomplete overlay blob');
    }
    final result = <AssetId, Uint8List>{};
    for (final entry in entries.entries) {
      final (offset, size) = entry.value;
      file.setPositionSync(offset);
      final bytes = file.readSync(size);
      if (bytes.length != size)
        throw const FormatException('Truncated overlay blob');
      result[entry.key] = bytes;
    }
    return result;
  } finally {
    file.closeSync();
  }
}
