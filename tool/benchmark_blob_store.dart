// Linux AOT probe: run each phase in a fresh process. ProcessInfo supplies
// peak RSS; CLOCK_PROCESS_CPUTIME_ID supplies CPU. Use the real cache filesystem.
import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
import 'dart:typed_data';
import '../lib/src/indexed_blob_store.dart';

int checksum(Uint8List bytes) {
  var a = 0;
  var b = 0;
  for (var start = 0; start < bytes.length; start += 5802) {
    final end = start + 5802 < bytes.length ? start + 5802 : bytes.length;
    for (var i = start; i < end; i++) {
      a += bytes[i];
      b += a;
    }
    a %= 255;
    b %= 255;
  }
  return (b << 8) | a;
}

List<int> cpu() {
  final s = File(
    '/proc/self/stat',
  ).readAsStringSync().split(') ').last.split(' ');
  return [int.parse(s[11]), int.parse(s[12])];
}

// Linux process CPU clock includes Dart mutator and GC threads. schedstat for
// the initial OS thread would incorrectly report zero while the mutator runs.
final _libc = DynamicLibrary.process();
final _malloc = _libc
    .lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >('malloc');
final _free = _libc
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'free',
    );
final _clock = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Int64>),
      int Function(int, Pointer<Int64>)
    >('clock_gettime');
int cpuMicros() {
  final pointer = _malloc(16).cast<Int64>();
  try {
    if (_clock(2, pointer) != 0)
      throw StateError('process CPU clock unavailable');
    return pointer[0] * 1000000 + pointer[1] ~/ 1000;
  } finally {
    _free(pointer.cast());
  }
}

void main(List<String> args) {
  final phase = args[0];
  final path = args[1];
  final count = int.parse(args[2]);
  final size = int.parse(args[3]);
  final store = IndexedBlobStore(path);
  final value = Uint8List(size);
  for (var i = 0; i < size; i++) {
    value[i] = i % 251;
  }
  // Exclude index construction from hot-get/write measurements.
  if (phase == 'get' || phase == 'write') {
    store.entryCount;
  }
  final metadataOnly = File('$path.index').existsSync();
  final indexPath = metadataOnly ? '$path.index' : path;
  final indexBytes = phase == 'index-only'
      ? File(indexPath).readAsBytesSync()
      : null;
  final cpuStart = cpuMicros();
  final before = cpu();
  final watch = Stopwatch()..start();
  var result = 0;
  switch (phase) {
    case 'seed':
    case 'write':
      for (var i = 0; i < count; i++) {
        if (!store.put('${phase == 'seed' ? 'old' : 'new'}-$i.linked', value)) {
          throw StateError('write failed');
        }
      }
    case 'index':
      result = store.entryCount;
    case 'load':
      result = File(indexPath).readAsBytesSync().length;
    case 'index-only':
      // Isolate UTF-8 decoding and map construction from I/O and validation.
      final bytes = indexBytes!;
      final index = <String, (int, int)>{};
      var pos = metadataOnly ? 16 : 0;
      while (pos < bytes.length) {
        final headerLength = metadataOnly ? 16 : 8;
        final header = ByteData.sublistView(bytes, pos, pos + headerLength);
        final keyLength = header.getUint32(0, Endian.little);
        final valueLength = header.getUint32(4, Endian.little);
        final key = utf8.decode(
          Uint8List.sublistView(
            bytes,
            pos + headerLength,
            pos + headerLength + keyLength,
          ),
        );
        final offset = metadataOnly
            ? header.getUint64(8, Endian.little) + 8 + keyLength
            : pos + 8 + keyLength;
        index[key] = (offset, valueLength);
        pos += metadataOnly
            ? 16 + keyLength + 4
            : 8 + keyLength + valueLength + 2;
      }
      result = index.length;
    case 'get':
      for (var i = 0; i < count; i++) {
        final got = store.get('old-$i.linked');
        if (got == null || got.length != size) throw StateError('miss');
        result += got.length;
      }
    case 'read':
      final file = File(path).openSync();
      // Sequential value reads from the data layout, excluding checksums/index.
      for (var i = 0; i < count; i++) {
        final header = ByteData.sublistView(file.readSync(8));
        final keyLength = header.getUint32(0, Endian.little);
        final length = header.getUint32(4, Endian.little);
        file.setPositionSync(file.positionSync() + keyLength);
        result += file.readSync(length).length;
        file.setPositionSync(file.positionSync() + 2);
      }
      file.closeSync();
    case 'checksum':
      for (var i = 0; i < count; i++) {
        result ^= checksum(value);
      }
    default:
      throw ArgumentError(phase);
  }
  watch.stop();
  final after = cpu();
  final cpuEnd = cpuMicros();
  print(
    jsonEncode({
      'phase': phase,
      'records': count,
      'value_bytes': size,
      'elapsed_us': watch.elapsedMicroseconds,
      'process_cpu_us': cpuEnd - cpuStart,
      'user_ticks': after[0] - before[0],
      'system_ticks': after[1] - before[1],
      'rss_bytes': ProcessInfo.currentRss,
      'peak_rss_bytes': ProcessInfo.maxRss,
      'result': result,
    }),
  );
  store.close();
}
