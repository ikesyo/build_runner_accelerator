import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/indexed_blob_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late IndexedBlobStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('indexed_blob_store_test');
    store = IndexedBlobStore('${dir.path}/store.bin');
  });

  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  test('miss on empty store', () {
    expect(store.get('absent'), isNull);
    expect(store.entryCount, 0);
  });

  test('put then get round-trips values', () {
    store.put('k1', Uint8List.fromList([1, 2, 3]));
    store.put('k2', Uint8List.fromList('hello'.codeUnits));
    expect(store.get('k1'), [1, 2, 3]);
    expect(String.fromCharCodes(store.get('k2')!), 'hello');
    expect(store.get('absent'), isNull);
    expect(store.entryCount, 2);
  });

  test('empty value is a hit', () {
    store.put('empty', Uint8List(0));
    final bytes = store.get('empty');
    expect(bytes, isNotNull);
    expect(bytes, isEmpty);
  });

  test('large values round-trip', () {
    final value = Uint8List(5 * 1024 * 1024)
      ..[0] = 7
      ..[5 * 1024 * 1024 - 1] = 9;
    store.put('big', value);
    final got = store.get('big')!;
    expect(got.length, value.length);
    expect(got[0], 7);
    expect(got[got.length - 1], 9);
  });

  test('fresh instance indexes the same file', () {
    store.put('k', Uint8List.fromList([42]));
    store.close();
    final reopened = IndexedBlobStore('${dir.path}/store.bin');
    addTearDown(reopened.close);
    expect(reopened.get('k'), [42]);
  });

  test('torn tail is ignored', () {
    store.put('good', Uint8List.fromList([1]));
    store.close();
    File('${dir.path}/store.bin').writeAsBytesSync(
      [255, 255, 255, 255, 0],
      mode: FileMode.append,
      flush: true,
    );
    final reopened = IndexedBlobStore('${dir.path}/store.bin');
    addTearDown(reopened.close);
    expect(reopened.get('good'), [1]);
    expect(reopened.entryCount, 1);
    // A torn tail does not prevent further appends: the writer truncates it.
    reopened.put('after', Uint8List.fromList([2]));
    expect(reopened.get('after'), [2]);
    reopened.close();
    // A third process sees both records — the torn bytes were removed.
    final third = IndexedBlobStore('${dir.path}/store.bin');
    addTearDown(third.close);
    expect(third.get('good'), [1]);
    expect(third.get('after'), [2]);
  });

  test('writer adopts records appended after its scan', () {
    store.get('prime');
    final other = IndexedBlobStore('${dir.path}/store.bin');
    addTearDown(other.close);
    other.put('later', Uint8List.fromList([8]));
    // The stale-indexed writer picks up the sibling's entry on its next put.
    store.put('mine', Uint8List.fromList([9]));
    expect(store.get('later'), [8]);
  });
}
