import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/indexed_blob_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late IndexedBlobPack store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('indexed_blob_store_test');
    store = IndexedBlobPack('${dir.path}/store.bin');
  });

  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  test('admission bounds unique keys and repeated updates', () {
    for (final repeated in [false, true]) {
      final path = '${dir.path}/bounded-$repeated';
      final bounded = IndexedBlobPack(path, maxRecords: 4);
      for (var i = 0; i < 40; i++) {
        expect(
          bounded.put(repeated ? 'same' : 'key-$i', Uint8List.fromList([i])),
          i < 4,
        );
      }
      expect(bounded.get(repeated ? 'same' : 'key-3'), [3]);
      final size = File(path).lengthSync();
      bounded.close();
      final reopened = IndexedBlobPack(path, maxRecords: 4);
      expect(reopened.get(repeated ? 'same' : 'key-3'), [3]);
      expect(reopened.put('extra', Uint8List(1)), isFalse);
      expect(File(path).lengthSync(), size);
      reopened.close();
    }
  });

  test('oversized existing history is never truncated by bounded scan', () {
    final path = '${dir.path}/existing';
    final writer = IndexedBlobPack(path);
    for (var i = 0; i < 10; i++) {
      expect(writer.put('key-$i', Uint8List.fromList([i])), isTrue);
    }
    expect(writer.put('key-0', Uint8List.fromList([99])), isTrue);
    final dataSize = File(path).lengthSync();
    final journalSize = File('$path.index').lengthSync();
    final bounded = IndexedBlobPack(path, maxRecords: 3);
    expect(bounded.entryCount, 0);
    expect(bounded.get('key-0'), isNull);
    expect(bounded.put('extra', Uint8List(1)), isFalse);
    expect(File(path).lengthSync(), dataSize);
    expect(File('$path.index').lengthSync(), journalSize);
    expect(writer.get('key-9'), [9]);
    bounded.close();
    writer.close();
  });

  test('data and journal budgets reject before writing a record', () {
    for (final dataBudget in [true, false]) {
      final path = '${dir.path}/bytes-$dataBudget';
      final bounded = IndexedBlobPack(
        path,
        maxDataBytes: dataBudget ? 12 : 100,
        maxJournalBytes: dataBudget ? 100 : 37,
      );
      expect(bounded.put('k', Uint8List(1)), isTrue);
      expect(bounded.put('x', Uint8List(1)), isFalse);
      expect(bounded.get('k'), [0]);
      expect(bounded.put('k', Uint8List(1)), isTrue);
      bounded.close();
    }
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
    final reopened = IndexedBlobPack('${dir.path}/store.bin');
    addTearDown(reopened.close);
    expect(reopened.get('k'), [42]);
  });

  test('reader refresh sees sibling appends without writing or reopening', () {
    store.put('existing', Uint8List.fromList([1]));
    final sibling = IndexedBlobPack('${dir.path}/store.bin');
    addTearDown(sibling.close);
    sibling.put('later.linked', Uint8List.fromList([8]));
    store.refresh();
    expect(store.get('later.linked'), [8]);
    expect(store.containsKeySuffix('.linked'), isTrue);
  });

  test('empty reader sees a newly created pack', () {
    expect(store.get('later'), isNull);
    final sibling = IndexedBlobPack('${dir.path}/store.bin');
    addTearDown(sibling.close);
    sibling.put('later', Uint8List.fromList([8]));
    store.refresh();
    expect(store.get('later'), [8]);
  });

  test('reader retries an incomplete publication without repairing it', () {
    store.put('existing', Uint8List.fromList([1]));
    final journal = File('${dir.path}/store.bin.index');
    final length = journal.lengthSync();
    final sibling = IndexedBlobPack('${dir.path}/store.bin');
    sibling.put('later', Uint8List.fromList([8]));
    sibling.close();
    final record = journal.readAsBytesSync().sublist(length);
    final handle = journal.openSync(mode: FileMode.append);
    handle.truncateSync(length + 9);
    handle.closeSync();
    store.refresh();
    expect(store.get('later'), isNull);
    expect(journal.lengthSync(), length + 9);
    journal.writeAsBytesSync(record.sublist(9), mode: FileMode.append);
    store.refresh();
    expect(store.get('later'), [8]);
  });

  for (final tailLength in [20, 21]) {
    test('reader follows torn-tail repair after $tailLength invalid bytes', () {
      store.put('existing', Uint8List.fromList([1]));
      final reader = IndexedBlobPack('${dir.path}/store.bin');
      addTearDown(reader.close);
      expect(reader.get('existing'), [1]);
      final file = File('${dir.path}/store.bin');
      file.writeAsBytesSync(
        List.filled(tailLength, 255),
        mode: FileMode.append,
      );
      final observedLength = file.lengthSync();
      reader.refresh();
      // Refresh never indexes the invalid tail. The writer repairs it and
      // publishes a complete record at that same boundary, even if the file
      // returns to its previous size or grows beyond it.
      expect(store.put('new.linked', Uint8List.fromList([8])), isTrue);
      expect(file.lengthSync(), greaterThanOrEqualTo(observedLength));
      reader.refresh();
      expect(reader.get('existing'), [1]);
      expect(reader.get('new.linked'), [8]);
    });
  }
  test('writer repairs incomplete publication even on an identical put', () {
    final value = Uint8List.fromList([7]);
    store.put('first', value);
    final journal = File('${dir.path}/store.bin.index');
    final end = journal.lengthSync();
    final data = File('${dir.path}/store.bin');
    final dataEnd = data.lengthSync();
    final sibling = IndexedBlobPack(data.path);
    sibling.put('lost', Uint8List.fromList([8]));
    sibling.close();
    final handle = journal.openSync(mode: FileMode.append);
    handle.truncateSync(journal.lengthSync() - 1);
    handle.closeSync();
    expect(store.put('first', value), isTrue);
    expect(journal.lengthSync(), end);
    expect(data.lengthSync(), dataEnd);
    expect(store.put('after', Uint8List.fromList([9])), isTrue);
    final reader = IndexedBlobPack(data.path);
    addTearDown(reader.close);
    expect(reader.get('first'), value);
    expect(reader.get('lost'), isNull);
    expect(reader.get('after'), [9]);
  });

  test('invalid journal generation is a miss and rebuilds safely', () {
    store.put('old', Uint8List.fromList([1]));
    final journal = File('${dir.path}/store.bin.index');
    final bytes = journal.readAsBytesSync()..[4] ^= 1;
    journal.writeAsBytesSync(bytes);
    store.refresh();
    expect(store.get('old'), isNull);
    expect(store.put('new', Uint8List.fromList([2])), isTrue);
    final reader = IndexedBlobPack('${dir.path}/store.bin');
    addTearDown(reader.close);
    expect(reader.get('old'), isNull);
    expect(reader.get('new'), [2]);
  });

  test('corrupt payload misses without hiding later published records', () {
    store.put('bad', Uint8List.fromList([1, 2, 3]));
    store.put('good', Uint8List.fromList([4]));
    final file = File('${dir.path}/store.bin');
    final bytes = file.readAsBytesSync()..[11] = 99;
    file.writeAsBytesSync(bytes);
    final reader = IndexedBlobPack(file.path);
    addTearDown(reader.close);
    expect(reader.get('bad'), isNull);
    expect(reader.get('good'), [4]);
    expect(reader.put('bad', Uint8List.fromList([1, 2, 3])), isTrue);
    expect(reader.get('good'), [4]);
    expect(reader.get('bad'), [1, 2, 3]);
  });

  test('lost journal discards unpublished data and rebuilds', () {
    store.put('old', Uint8List.fromList([1]));
    store.close();
    File('${dir.path}/store.bin.index').deleteSync();
    final reader = IndexedBlobPack('${dir.path}/store.bin');
    addTearDown(reader.close);
    expect(reader.get('old'), isNull);
    expect(reader.put('new', Uint8List.fromList([2])), isTrue);
    expect(reader.get('new'), [2]);
    expect(reader.get('old'), isNull);
  });

  test('corrupt publication header is rejected and repaired under lock', () {
    store.put('first', Uint8List.fromList([1]));
    final journal = File('${dir.path}/store.bin.index');
    final end = journal.lengthSync();
    store.put('second', Uint8List.fromList([2]));
    final bytes = journal.readAsBytesSync()..[end + 4] ^= 1;
    journal.writeAsBytesSync(bytes);
    final reader = IndexedBlobPack('${dir.path}/store.bin');
    addTearDown(reader.close);
    expect(reader.get('first'), [1]);
    expect(reader.get('second'), isNull);
    expect(reader.put('third!', Uint8List.fromList([3])), isTrue);
    reader.refresh();
    expect(reader.get('third!'), [3]);
    // A stale offset now points at a different key; it must never hit.
    expect(store.get('second'), isNull);
    store.refresh();
    expect(store.get('third!'), [3]);
  });

  test('data loss resets publication and never returns stale offsets', () {
    store.put('first', Uint8List.fromList([1]));
    final file = File('${dir.path}/store.bin');
    final handle = file.openSync(mode: FileMode.append);
    handle.truncateSync(0);
    handle.closeSync();
    expect(store.get('first'), isNull);
    expect(store.put('other', Uint8List.fromList([2])), isTrue);
    final reader = IndexedBlobPack(file.path);
    addTearDown(reader.close);
    expect(reader.get('first'), isNull);
    expect(reader.get('other'), [2]);
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
        final reopened = IndexedBlobPack(file.path);
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
    final other = IndexedBlobPack('${dir.path}/store.bin');
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
    final reopened = IndexedBlobPack('${dir.path}/store.bin');
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
    // A fresh reader selects the published replacement and deduplicates it
    // without discarding any earlier data records.
    final reopened = IndexedBlobPack(file.path);
    addTearDown(reopened.close);
    reopened.put('k', value);
    expect(reopened.get('k'), value);
    final third = IndexedBlobPack(file.path);
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
    final reopened = IndexedBlobPack(file.path);
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
    final reopened = IndexedBlobPack('${dir.path}/store.bin');
    addTearDown(reopened.close);
    expect(reopened.get('good'), [1]);
    expect(reopened.entryCount, 1);
    // A torn tail does not prevent further appends: the writer truncates it.
    reopened.put('after', Uint8List.fromList([2]));
    expect(reopened.get('after'), [2]);
    reopened.close();
    // A third process sees both records — the torn bytes were removed.
    final third = IndexedBlobPack('${dir.path}/store.bin');
    addTearDown(third.close);
    expect(third.get('good'), [1]);
    expect(third.get('after'), [2]);
  });

  test('writer adopts records appended after its scan', () {
    store.get('prime');
    final other = IndexedBlobPack('${dir.path}/store.bin');
    addTearDown(other.close);
    other.put('later', Uint8List.fromList([8]));
    // The stale-indexed writer picks up the sibling's entry on its next put.
    store.put('mine', Uint8List.fromList([9]));
    expect(store.get('later'), [8]);
  });

  for (final bounded in [false, true]) {
    test('four concurrent processes append safely (bounded=$bounded)', () async {
      final path = '${dir.path}/store.bin';
      final processes = await Future.wait([
        for (var worker = 0; worker < 4; worker++)
          Process.start(Platform.resolvedExecutable, [
            '--packages=${File('.dart_tool/package_config.json').absolute.path}',
            'test/indexed_blob_store_process.dart',
            path,
            '$worker',
            if (bounded) '32',
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
        expect(
          await processes[worker].exitCode,
          0,
          reason: await errors[worker],
        );
      }
      if (bounded) {
        expect(store.entryCount, 32);
        for (var round = 0; round < 32; round++) {
          for (final key in [
            'shared-$round.resolved',
            for (var worker = 0; worker < 4; worker++) 'worker-$worker-$round',
          ]) {
            final value = store.get(key);
            if (value != null) expect(value, [round]);
          }
        }
        return;
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
}
