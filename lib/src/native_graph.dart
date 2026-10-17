import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reports retained history only after validating the complete current graph.
///
/// Release-coupled with rust/src/graph.rs. Obsolete/corrupt state belongs to a
/// native cold rebuild, not stock fallback.
bool hasRetainedNativeOutputState(String root) {
  final file = File('$root/.dart_tool/build_runner_accelerator/graph-v3.bin');
  if (!file.existsSync()) return false;
  final input = file.openSync();
  try {
    final length = input.lengthSync();
    if (length < 9 || length > 9 + 256 * 1024 * 1024) return false;
    final header = input.readSync(9);
    if (header.length != 9 ||
        header[0] != 0x42 ||
        header[1] != 0x52 ||
        header[2] != 0x41 ||
        header[3] != 0x47 ||
        header[4] != 3 ||
        ByteData.sublistView(header).getUint32(5) != length - 9) {
      return false;
    }
    final schema = input.readSync(4);
    if (schema.length != 4 || ByteData.sublistView(schema).getUint32(0) != 4) {
      return false;
    }
    // A false/invalid history byte cannot route to stock. Most graphs take
    // this cheap path; only a candidate true flag needs full validation.
    input.setPositionSync(length - 1);
    if (input.readByteSync() != 1) return false;
    input.setPositionSync(9);
    final reader = _GraphReader(input.readSync(length - 9));
    if (reader.integer() != 4) return false;
    reader.string(); // config digest
    reader.map(() {
      reader.boolean();
      reader.string();
      reader.take(8);
    });
    reader.map(reader.action);
    reader.map(reader.strings); // resolver edges
    reader.map(reader.boolean); // output locations
    reader.map(reader.strings); // stock input order
    reader.map(() => reader.map(reader.strings)); // stock glob members
    reader.strings(); // watch generated sources
    final retained = reader.boolean();
    return reader.offset == length - 9 && retained;
  } on FormatException {
    return false;
  } finally {
    input.closeSync();
  }
}

/// Validates format-3 structure without constructing the incremental graph.
final class _GraphReader {
  _GraphReader(this.bytes);
  final Uint8List bytes;
  int offset = 0;

  Uint8List take(int count) {
    final end = offset + count;
    if (end > bytes.length) throw const FormatException('Truncated graph');
    final value = Uint8List.sublistView(bytes, offset, end);
    offset = end;
    return value;
  }

  int integer() => ByteData.sublistView(take(4)).getUint32(0);

  int count() {
    final value = integer();
    if (value > 4000000)
      throw const FormatException('Graph collection too large');
    return value;
  }

  bool boolean() => switch (take(1)[0]) {
    0 => false,
    1 => true,
    _ => throw const FormatException('Invalid graph boolean'),
  };

  String string() => utf8.decode(take(integer()));

  void strings() {
    final length = count();
    for (var i = 0; i < length; i++) {
      string();
    }
  }

  void map(void Function() value) {
    final length = count();
    final keys = <String>{};
    for (var i = 0; i < length; i++) {
      if (!keys.add(string()))
        throw const FormatException('Duplicate graph key');
      value();
    }
  }

  void action() {
    string();
    string(); // builder, input
    strings();
    strings();
    strings(); // reads, resolver reads, entrypoints
    final globs = count();
    for (var i = 0; i < globs; i++) {
      string();
      string();
    }
    strings(); // outputs
    map(string); // output digests
    string(); // status
  }
}
