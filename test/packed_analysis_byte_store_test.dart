import 'dart:io';
import 'dart:typed_data';

// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:build_runner_accelerator/src/packed_analysis_byte_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  final value = Uint8List.fromList([1, 2, 3]);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('packed-analysis-store-');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File seed(String key) {
    final file = File(p.join(dir.path, key.substring(0, 2), key));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(FileByteStoreValidator().wrapData(value));
    return file;
  }

  test('linking readiness sees sibling appends but ignores syntax entries', () {
    final reader = PackedAnalysisByteStore(dir.path);
    final writer = PackedAnalysisByteStore(dir.path);
    addTearDown(reader.close);
    addTearDown(writer.close);
    expect(reader.hasLinkedEntries, isFalse);
    writer.putGet('ab123.unlinked2', value);
    expect(reader.hasLinkedEntries, isFalse);
    writer.putGet('cd456.linked', value);
    expect(reader.hasLinkedEntries, isTrue);
    expect(reader.get('cd456.linked'), value);
  });

  test('earlier formats are ignored without migration', () {
    final legacy = seed('ab123.resolved');
    final old = File(p.join(dir.path, 'store.v1.bin'))
      ..writeAsStringSync('old');
    final store = PackedAnalysisByteStore(dir.path);
    addTearDown(store.close);
    expect(store.get('ab123.resolved'), isNull);
    expect(store.putGet('ab123.resolved', value), value);
    expect(store.get('ab123.resolved'), value);
    expect(legacy.existsSync(), isTrue);
    expect(old.readAsStringSync(), 'old');
  });

  test('cache write failure returns caller bytes and read remains a miss', () {
    Directory(p.join(dir.path, 'store.v2.bin')).createSync();
    final store = PackedAnalysisByteStore(dir.path);
    addTearDown(store.close);
    expect(store.putGet('ab123.resolved', value), value);
    expect(store.get('ab123.resolved'), isNull);
  });
}
