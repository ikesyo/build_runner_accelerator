import 'dart:convert';
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

  test('reader refresh sees sibling appends without writing or reopening', () {
    store.put('existing', Uint8List.fromList([1]));
    final sibling = IndexedBlobStore('${dir.path}/store.bin');
    addTearDown(sibling.close);
    sibling.put('later.linked', Uint8List.fromList([8]));
    store.refresh();
    expect(store.get('later.linked'), [8]);
    expect(store.containsKeySuffix('.linked'), isTrue);
  });

  test('empty reader sees a newly created pack', () {
    expect(store.get('later'), isNull);
    final sibling = IndexedBlobStore('${dir.path}/store.bin');
    addTearDown(sibling.close);
    sibling.put('later', Uint8List.fromList([8]));
    store.refresh();
    expect(store.get('later'), [8]);
  });

  test('reader leaves a partial tail intact and retries after completion', () {
    store.put('existing', Uint8List.fromList([1]));
    final siblingFile = File('${dir.path}/sibling.bin');
    final sibling = IndexedBlobStore(siblingFile.path);
    sibling.put('later', Uint8List.fromList([8]));
    sibling.close();
    final record = siblingFile.readAsBytesSync();
    final file = File('${dir.path}/store.bin');
    final length = file.lengthSync();
    file.writeAsBytesSync(record.sublist(0, 9), mode: FileMode.append);
    store.refresh();
    expect(store.get('later'), isNull);
    expect(file.lengthSync(), length + 9);
    file.writeAsBytesSync(record.sublist(9), mode: FileMode.append);
    store.refresh();
    expect(store.get('later'), [8]);
  });

  test('identical writes do not grow the pack across builds', () {
    final file = File('${dir.path}/store.bin');
    for (final value in [
      Uint8List(0),
      Uint8List.fromList([1, 2, 3]),
    ]) {
      final key = 'key-${value.length}.resolved';
      store.put(key, value);
      final length = file.lengthSync();
      for (var build = 0; build < 32; build++) {
        store.put(key, Uint8List.fromList(value));
        final reopened = IndexedBlobStore(file.path);
        try {
          reopened.put(key, Uint8List.fromList(value));
          expect(reopened.get(key), value);
        } finally {
          reopened.close();
        }
        expect(file.lengthSync(), length);
      }
    }
  });

  test('stale writer adopts identical sibling writes before deduplicating', () {
    store.get('prime');
    final other = IndexedBlobStore('${dir.path}/store.bin');
    addTearDown(other.close);
    other.put('shared', Uint8List.fromList([8]));
    final length = File('${dir.path}/store.bin').lengthSync();
    store.put('shared', Uint8List.fromList([8]));
    expect(File('${dir.path}/store.bin').lengthSync(), length);
    expect(store.get('shared'), [8]);
  });

  test('different values under the same key remain updates', () {
    store.put('k', Uint8List.fromList([0, 0, 0]));
    // Same length and Fletcher-16 checksum: equality must compare bytes.
    store.put('k', Uint8List.fromList([255, 255, 255]));
    expect(store.get('k'), [255, 255, 255]);
    store.put('k', Uint8List.fromList([4]));
    expect(store.get('k'), [4]);
    final reopened = IndexedBlobStore('${dir.path}/store.bin');
    addTearDown(reopened.close);
    expect(reopened.get('k'), [4]);
  });

  test('identical put repairs a corrupt indexed value', () {
    final value = Uint8List.fromList([1, 2, 3]);
    store.put('k', value);
    final file = File('${dir.path}/store.bin');
    final bytes = file.readAsBytesSync()..[9] = 99;
    file.writeAsBytesSync(bytes, flush: true);
    expect(store.get('k'), isNull);
    store.put('k', value);
    expect(store.get('k'), value);
    // A fresh scan encounters the corrupt record first. Its next put must
    // truncate that tail and restore a record visible to later readers.
    final reopened = IndexedBlobStore(file.path);
    addTearDown(reopened.close);
    reopened.put('k', value);
    expect(reopened.get('k'), value);
    final third = IndexedBlobStore(file.path);
    addTearDown(third.close);
    expect(third.get('k'), value);
  });

  test('deduplicated put still truncates a torn tail', () {
    final value = Uint8List.fromList([7]);
    store.put('k', value);
    final file = File('${dir.path}/store.bin');
    final length = file.lengthSync();
    file.writeAsBytesSync([255, 255, 255], mode: FileMode.append, flush: true);
    store.put('k', value);
    expect(file.lengthSync(), length);
    store.put('next', Uint8List.fromList([8]));
    final reopened = IndexedBlobStore(file.path);
    addTearDown(reopened.close);
    expect(reopened.get('k'), value);
    expect(reopened.get('next'), [8]);
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

  test('four concurrent processes append each shared value once', () async {
    final path = '${dir.path}/store.bin';
    final processes = await Future.wait([
      for (var worker = 0; worker < 4; worker++)
        Process.start(Platform.resolvedExecutable, [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          'test/indexed_blob_store_process.dart',
          path,
          '$worker',
        ]),
    ]);
    addTearDown(() {
      for (final process in processes) {
        process.kill();
      }
    });
    final errors = [
      for (final process in processes)
        process.stderr.transform(utf8.decoder).join(),
    ];
    await Future.wait([
      for (final process in processes)
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .then((line) => expect(line, 'ready')),
    ]);
    for (final process in processes) {
      process.stdin.writeln('start');
      await process.stdin.close();
    }
    var expectedLength = 0;
    for (var round = 0; round < 32; round++) {
      for (final key in [
        'shared-$round.resolved',
        for (var worker = 0; worker < 4; worker++) 'worker-$worker-$round',
      ]) {
        expectedLength += 8 + utf8.encode(key).length + 1 + 2;
      }
    }
    for (var worker = 0; worker < 4; worker++) {
      expect(await processes[worker].exitCode, 0, reason: await errors[worker]);
    }
    expect(File(path).lengthSync(), expectedLength);
    expect(store.entryCount, 160);
    for (var round = 0; round < 32; round++) {
      expect(store.get('shared-$round.resolved'), [round]);
      for (var worker = 0; worker < 4; worker++) {
        expect(store.get('worker-$worker-$round'), [round]);
      }
    }
  });
}
