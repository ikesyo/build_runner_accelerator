import 'dart:io';
import 'dart:typed_data';

// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:build_runner_accelerator/src/indexed_blob_store.dart';
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

  test('legacy hit is deleted after migration and survives reopening', () {
    final legacy = seed('ab123.resolved');
    final unread = seed('cd456.linked');
    final store = PackedAnalysisByteStore(dir.path);
    expect(store.get('ab123.resolved'), value);
    expect(legacy.existsSync(), isFalse);
    expect(unread.existsSync(), isTrue);
    store.close();
    final reopened = PackedAnalysisByteStore(dir.path);
    addTearDown(reopened.close);
    expect(reopened.get('ab123.resolved'), value);
  });

  test('already migrated packed hit removes legacy copy', () {
    final legacy = seed('ab123.resolved');
    final pack = IndexedBlobStore(p.join(dir.path, 'store.v1.bin'));
    expect(pack.put('ab123.resolved', value), isTrue);
    pack.close();
    final store = PackedAnalysisByteStore(dir.path);
    addTearDown(store.close);
    expect(store.get('ab123.resolved'), value);
    expect(legacy.existsSync(), isFalse);
  });

  test('failed packed write preserves readable legacy entry', () {
    final legacy = seed('ab123.resolved');
    // A directory at the pack path makes opening a writable file fail.
    Directory(p.join(dir.path, 'store.v1.bin')).createSync();
    final store = PackedAnalysisByteStore(dir.path);
    addTearDown(store.close);
    expect(store.get('ab123.resolved'), value);
    expect(legacy.existsSync(), isTrue);
    expect(FileByteStore(dir.path).get('ab123.resolved'), value);
  });

  test('putGet removes only its successfully packed legacy entry', () {
    final legacy = seed('ab123.resolved');
    final unrelated = File(p.join(dir.path, 'ab', 'unrelated'))
      ..writeAsStringSync('keep');
    final temp = File(p.join(dir.path, 'ab123.resolved-temp-123'))
      ..writeAsStringSync('keep');
    final store = PackedAnalysisByteStore(dir.path);
    addTearDown(store.close);
    final replacement = Uint8List.fromList([4]);
    expect(store.putGet('ab123.resolved', replacement), replacement);
    expect(store.get('ab123.resolved'), replacement);
    expect(legacy.existsSync(), isFalse);
    expect(unrelated.readAsStringSync(), 'keep');
    expect(temp.readAsStringSync(), 'keep');
  });

  test('sibling migrations tolerate another worker deleting the shard', () {
    final legacy = seed('ab123.resolved');
    final first = PackedAnalysisByteStore(dir.path);
    final second = PackedAnalysisByteStore(dir.path);
    addTearDown(first.close);
    addTearDown(second.close);
    expect(first.get('missing'), isNull);
    expect(second.get('ab123.resolved'), value);
    final length = File(p.join(dir.path, 'store.v1.bin')).lengthSync();
    // first's pack index predates second's migration. A write adopts it.
    expect(first.putGet('ab123.resolved', value), value);
    expect(first.get('ab123.resolved'), value);
    expect(legacy.existsSync(), isFalse);
    expect(File(p.join(dir.path, 'store.v1.bin')).lengthSync(), length);
  });
}
