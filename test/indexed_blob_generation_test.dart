import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/indexed_blob_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class RemovedLeaseFile implements File {
  RemovedLeaseFile(this.file, {this.permissionDenied = false});
  final File file;
  final bool permissionDenied;
  bool deleteAttempted = false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      file.openSync(mode: mode);

  @override
  void deleteSync({bool recursive = false}) {
    deleteAttempted = true;
    if (permissionDenied) {
      throw FileSystemException(
        'Access denied',
        file.path,
        const OSError('', 13),
      );
    }
    // Model the owner removing its lease after the inactive-lock probe.
    file.deleteSync();
    file.deleteSync();
  }
}

final class Peer {
  Peer(this.process, this.lines, this.errors);
  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;
  static Future<Peer> start(String path, int records) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=${File('.dart_tool/package_config.json').absolute.path}',
      'test/indexed_blob_generation_process.dart',
      path,
      '$records',
    ]);
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final peer = Peer(
      process,
      lines,
      process.stderr.transform(utf8.decoder).join(),
    );
    addTearDown(peer.terminate);
    expect(await lines.moveNext(), isTrue);
    expect(lines.current, 'ready');
    return peer;
  }

  Future<dynamic> command(List<Object> command) async {
    process.stdin.writeln(jsonEncode(command));
    expect(await lines.moveNext(), isTrue, reason: 'peer terminated');
    return jsonDecode(lines.current);
  }

  Future<void> terminate() async {
    process.kill();
    process.stdin.close().ignore();
    await process.exitCode;
    await lines.cancel();
  }

  Future<void> stop() async {
    await command(['exit']);
    // The peer explicitly exits after flushing its reply; pipe teardown may
    // finish after that on Windows and must not hold up process reaping.
    process.stdin.close().ignore();
    expect(await process.exitCode, 0, reason: await errors);
    await lines.cancel();
  }
}

// Cache I/O is nonblocking and may miss while termination cleanup or a file
// sharing conflict settles on Windows. Require eventual recovery, and keep
// value assertions inside each attempt so a wrong value fails immediately.
Future<void> retryRecovery(bool Function() attempt) async {
  final deadline = Stopwatch()..start();
  while (!attempt()) {
    if (deadline.elapsed > const Duration(seconds: 5)) {
      fail('Cache did not recover after process termination');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory directory;
  late String path;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('blob-generations-');
    path = '${directory.path}/store';
  });
  tearDown(() async {
    await retryRecovery(() {
      try {
        directory.deleteSync(recursive: true);
        return true;
      } on PathAccessException catch (error) {
        // Process termination can leave a transient Windows sharing violation.
        // Persistent handles and every other deletion error must still fail.
        if (!Platform.isWindows || error.osError?.errorCode != 32) rethrow;
        return false;
      }
    });
  });
  List<Directory> generations() =>
      Directory('$path.generations').listSync().whereType<Directory>().toList();

  for (final permissionDenied in [false, true]) {
    test(
      'lease pruning ${permissionDenied ? 'retains access errors' : 'tolerates concurrent removal'}',
      () {
        final writer = IndexedBlobStore(path);
        expect(writer.put('saved', Uint8List.fromList([42])), isTrue);
        writer.close();
        final lease = File('${generations().single.path}/lease-0-race')
          ..writeAsStringSync('');
        final raced = RemovedLeaseFile(
          lease,
          permissionDenied: permissionDenied,
        );
        final reader = IndexedBlobStore(path);
        addTearDown(reader.close);
        IOOverrides.runZoned(
          () {
            expect(reader.get('saved'), permissionDenied ? isNull : [42]);
            expect(raced.deleteAttempted, isTrue);
            if (!permissionDenied) {
              expect(reader.put('next', Uint8List.fromList([43])), isTrue);
              expect(reader.get('next'), [43]);
            }
          },
          createFile: (name) => p.equals(name, lease.path)
              ? raced
              : Zone.root.run(() => File(name)),
        );
        expect(lease.existsSync(), permissionDenied);
        if (permissionDenied) {
          lease.deleteSync();
          reader.refresh();
          expect(reader.get('saved'), [42]);
        }
      },
    );
  }

  test(
    'distinct keys and repeated updates keep saving across many rollovers',
    () {
      for (final repeated in [false, true]) {
        final store = IndexedBlobStore('$path-$repeated', maxRecords: 4);
        addTearDown(store.close);
        for (var i = 0; i < 100; i++) {
          final key = repeated ? 'same' : 'key-$i';
          expect(store.put(key, Uint8List.fromList([i])), isTrue);
          expect(store.get(key), [i]);
        }
        store.close();
        final reopened = IndexedBlobStore('$path-$repeated', maxRecords: 4);
        addTearDown(reopened.close);
        expect(reopened.get(repeated ? 'same' : 'key-99'), [99]);
        reopened.close();
        expect(
          Directory(
            '$path-$repeated.generations',
          ).listSync().whereType<Directory>().length,
          1,
        );
      }
    },
  );

  test('byte budgets rotate and oversized values do not churn generations', () {
    final store = IndexedBlobStore(path, maxDataBytes: 24, maxJournalBytes: 58);
    addTearDown(store.close);
    addTearDown(store.close);
    for (var i = 0; i < 20; i++) {
      expect(store.put('k', Uint8List.fromList([i])), isTrue);
      expect(store.get('k'), [i]);
    }
    final count = generations().length;
    expect(store.put('large', Uint8List(100)), isFalse);
    expect(generations().length, count);
    for (final generation in generations()) {
      expect(
        File('${generation.path}/data').lengthSync(),
        lessThanOrEqualTo(24),
      );
      expect(
        File('${generation.path}/data.index').lengthSync(),
        lessThanOrEqualTo(58),
      );
    }
  });

  test('rollover carries bounded recent values and reuses them after open', () {
    final store = IndexedBlobStore(path, maxRecords: 64);
    addTearDown(store.close);
    for (var i = 0; i < 64; i++) {
      expect(store.put('key-$i.linked', Uint8List.fromList([i])), isTrue);
    }
    expect(store.put('new', Uint8List.fromList([99])), isTrue);
    expect(store.get('key-59.linked'), isNull);
    for (var i = 60; i < 64; i++) {
      expect(store.get('key-$i.linked'), [i]);
    }
    expect(store.entryCount, 5);
    expect(store.containsKeySuffix('.linked'), isTrue);
    store.close();
    final reopened = IndexedBlobStore(path, maxRecords: 64);
    addTearDown(reopened.close);
    expect(reopened.get('key-63.linked'), [63]);
    expect(reopened.get('new'), [99]);
    expect(generations().length, 1);
  });

  test('carryover orders updated keys by their latest record', () {
    for (final requestedKey in ['new', 'updated']) {
      final store = IndexedBlobStore('$path-$requestedKey', maxRecords: 64);
      addTearDown(store.close);
      expect(store.put('updated', Uint8List.fromList([1])), isTrue);
      for (var i = 0; i < 62; i++) {
        expect(store.put('key-$i', Uint8List.fromList([i])), isTrue);
      }
      expect(store.put('updated', Uint8List.fromList([42])), isTrue);
      expect(store.put(requestedKey, Uint8List.fromList([99])), isTrue);
      expect(store.get('updated'), [requestedKey == 'updated' ? 99 : 42]);
      expect(store.get('key-61'), [61]);
      expect(store.get('key-0'), isNull);
      store.close();
    }
  });

  test('carryover reserves room for a full-budget requested value', () {
    final store = IndexedBlobStore(path, maxRecords: 64, maxDataBytes: 4096);
    addTearDown(store.close);
    for (var i = 0; i < 64; i++) {
      expect(store.put('key-$i', Uint8List.fromList([i])), isTrue);
    }
    final large = Uint8List(4096 - 10 - 'large'.length)..[0] = 42;
    expect(store.put('large', large), isTrue);
    expect(store.get('large'), large);
    expect(store.get('key-63'), isNull);
    expect(store.entryCount, 1);
    expect(File('${generations().single.path}/data').lengthSync(), 4096);
  });

  test('corrupt values are omitted from carryover', () {
    final store = IndexedBlobStore(path, maxRecords: 64);
    addTearDown(store.close);
    for (var i = 0; i < 64; i++) {
      expect(store.put('key-$i', Uint8List.fromList([i])), isTrue);
    }
    final data = File('${generations().single.path}/data');
    final handle = data.openSync(mode: FileMode.append);
    handle.setPositionSync(handle.lengthSync() - 3);
    handle.writeByteSync(0);
    handle.closeSync();
    expect(store.put('new', Uint8List.fromList([99])), isTrue);
    expect(store.get('key-63'), isNull);
    expect(store.get('key-62'), [62]);
    expect(store.get('new'), [99]);
  });

  test('carryover reserves journal header and requested key metadata', () {
    const journalLimit = 16 + 64 * 24;
    final store = IndexedBlobStore(
      path,
      maxRecords: 64,
      maxJournalBytes: journalLimit,
    );
    addTearDown(store.close);
    for (var i = 0; i < 64; i++) {
      expect(store.put('$i'.padLeft(4, '0'), Uint8List.fromList([i])), isTrue);
    }
    final key = 'k' * (journalLimit - 36);
    expect(store.put(key, Uint8List.fromList([99])), isTrue);
    expect(store.get(key), [99]);
    expect(store.get('0063'), isNull);
    expect(store.entryCount, 1);
    expect(
      File('${generations().single.path}/data.index').lengthSync(),
      journalLimit,
    );
  });

  test(
    'leased old generation survives and its writer can follow current',
    () async {
      final old = await Peer.start(path, 4);
      expect(await old.command(['put', 'old', 7]), isTrue);
      final writer = IndexedBlobStore(path, maxRecords: 4);
      addTearDown(writer.close);
      for (var i = 0; i < 40; i++) {
        expect(writer.put('key-$i', Uint8List.fromList([i])), isTrue);
      }
      expect(generations().length, 2);
      expect(await old.command(['get', 'old']), [7]);
      for (var i = 0; i < 8; i++) {
        expect(await old.command(['put', 'peer-$i', i]), isTrue);
        expect(await old.command(['get', 'peer-$i']), [i]);
      }
      await old.stop();
      writer.refresh();
      writer.close();
      final reader = IndexedBlobStore(path, maxRecords: 4);
      addTearDown(reader.close);
      reader.refresh();
      expect(reader.get('peer-7'), [7]);
      expect(generations().length, 1);
      reader.close();
    },
  );

  test('same-process leases are retained until their stores close', () {
    final old = IndexedBlobStore(path, maxRecords: 2);
    addTearDown(old.close);
    expect(old.put('old', Uint8List.fromList([9])), isTrue);
    final writer = IndexedBlobStore(path, maxRecords: 2);
    addTearDown(writer.close);
    for (var i = 0; i < 20; i++) {
      expect(writer.put('key-$i', Uint8List.fromList([i])), isTrue);
    }
    expect(old.get('old'), [9]);
    expect(generations().length, 2);
    old.close();
    writer.close();
    final reopened = IndexedBlobStore(path, maxRecords: 2)..refresh();
    addTearDown(reopened.close);
    expect(generations().length, 1);
    reopened.close();
  });

  test(
    'refresh adopts leased-pack publications while control is busy',
    () async {
      final reader = IndexedBlobStore(path);
      addTearDown(reader.close);
      expect(reader.put('existing', Uint8List.fromList([1])), isTrue);
      final peer = await Peer.start(path, 65536);
      expect(await peer.command(['put', 'later', 11]), isTrue);
      expect(reader.get('later'), isNull);
      expect(await peer.command(['hold-control']), isTrue);
      reader.refresh();
      expect(reader.get('later'), [11]);
      await peer.terminate();
    },
  );

  test(
    'four processes race rollovers and reuse a surviving generation',
    () async {
      final peers = await Future.wait(
        List.generate(4, (_) => Peer.start(path, 64)),
      );
      await Future.wait(
        List.generate(4, (worker) async {
          for (var i = 0; i < 80; i++) {
            final key = 'worker-$worker-$i';
            expect(await peers[worker].command(['put', key, i]), isTrue);
            final value = await peers[worker].command(['get', key]);
            // Windows mandatory writer locks may cause a transient miss. A
            // successful read must still match the key's exact value.
            if (value != null) expect(value, [i]);
          }
        }),
      );
      // All writers are now quiet, and each peer still leases its last pack.
      // Require reuse here rather than accepting permanent misses as success.
      for (var worker = 0; worker < peers.length; worker++) {
        expect(await peers[worker].command(['get', 'worker-$worker-79']), [79]);
      }
      await Future.wait(peers.map((peer) => peer.stop()));
      final reader = IndexedBlobStore(path, maxRecords: 64)..refresh();
      addTearDown(reader.close);
      expect(generations().length, 1);
      expect(
        [
          for (var worker = 0; worker < 4; worker++)
            reader.get('worker-$worker-79'),
        ].whereType<Uint8List>(),
        isNotEmpty,
      );
      reader.close();
    },
  );

  test('killed old reader releases lease and torn pointer recovers', () async {
    final peer = await Peer.start(path, 2);
    expect(await peer.command(['put', 'old', 1]), isTrue);
    final writer = IndexedBlobStore(path, maxRecords: 2);
    addTearDown(writer.close);
    for (var i = 0; i < 8; i++) {
      expect(writer.put('key-$i', Uint8List.fromList([i])), isTrue);
    }
    writer.close();
    expect(generations().length, 2);
    expect(await peer.command(['tear-pointer']), isTrue);
    peer.process.kill(
      Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
    );
    await peer.process.exitCode;
    await peer.lines.cancel();
    final recovered = IndexedBlobStore(path, maxRecords: 2);
    addTearDown(recovered.close);
    expect(recovered.get('old'), isNull);
    await retryRecovery(() {
      recovered.refresh();
      return recovered.put('new', Uint8List.fromList([42])) &&
          generations().length == 1;
    });
    expect(recovered.get('new'), [42]);
    expect(generations().length, 1);
    recovered.close();
  });

  test(
    'killed partial writer is repaired without losing published values',
    () async {
      final peer = await Peer.start(path, 4);
      expect(await peer.command(['put', 'published', 11]), isTrue);
      expect(await peer.command(['partial-record']), isTrue);
      peer.process.kill(
        Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
      );
      await peer.process.exitCode;
      await peer.lines.cancel();
      final recovered = IndexedBlobStore(path, maxRecords: 4);
      addTearDown(recovered.close);
      await retryRecovery(() {
        recovered.refresh();
        final value = recovered.get('published');
        if (value == null) return false;
        expect(value, [11]);
        return recovered.put('after', Uint8List.fromList([12]));
      });
      expect(recovered.get('after'), [12]);
      recovered.close();
    },
  );

  test('interrupted reclamation leaves only a retryable orphan', () async {
    final peer = await Peer.start(path, 4);
    expect(await peer.command(['put', 'published', 11]), isTrue);
    final orphan = 'a' * 32;
    final directory = Directory('$path.generations/$orphan')..createSync();
    File('${directory.path}/data').writeAsBytesSync([0]);
    File('${directory.path}/data.index').writeAsBytesSync([0]);
    expect(await peer.command(['partial-reclaim', orphan]), isTrue);
    peer.process.kill(
      Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
    );
    await peer.process.exitCode;
    await peer.lines.cancel();
    final recovered = IndexedBlobStore(path, maxRecords: 4);
    addTearDown(recovered.close);
    await retryRecovery(() {
      recovered.refresh();
      final value = recovered.get('published');
      if (value == null) return false;
      expect(value, [11]);
      return !directory.existsSync();
    });
    expect(directory.existsSync(), isFalse);
    expect(recovered.put('after', Uint8List.fromList([12])), isTrue);
    recovered.close();
  });

  test(
    'killed seed writer leaves current usable and its orphan reclaimable',
    () async {
      final peer = await Peer.start(path, 64);
      expect(await peer.command(['put', 'published', 11]), isTrue);
      final reader = IndexedBlobStore(path, maxRecords: 64);
      addTearDown(reader.close);
      expect(reader.get('published'), [11]);
      final orphan = 'c' * 32;
      expect(await peer.command(['partial-seed', orphan]), isTrue);
      expect(reader.get('published'), [11]);
      expect(reader.get('unpublished'), isNull);
      peer.process.kill(
        Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
      );
      await peer.process.exitCode;
      await peer.lines.cancel();
      final recovered = IndexedBlobStore(path, maxRecords: 64);
      addTearDown(recovered.close);
      await retryRecovery(() {
        recovered.refresh();
        final value = recovered.get('published');
        if (value == null) return false;
        expect(value, [11]);
        return !Directory('$path.generations/$orphan').existsSync();
      });
      expect(recovered.get('unpublished'), isNull);
      expect(recovered.put('after', Uint8List.fromList([12])), isTrue);
      expect(recovered.get('after'), [12]);
    },
  );

  test(
    'shutdown lease leftovers are pruned without requiring rollover',
    () async {
      for (var i = 0; i < 6; i++) {
        final peer = await Peer.start(path, 4);
        expect(await peer.command(['put', 'same', 1]), isTrue);
        expect(await peer.command(['exit-without-close']), isTrue);
        expect(await peer.process.exitCode, 0);
        await peer.lines.cancel();
        expect(
          Directory('$path.generations')
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) => f.path
                    .split(Platform.pathSeparator)
                    .last
                    .startsWith('lease-'),
              )
              .length,
          1,
        );
      }
      final reader = IndexedBlobStore(path, maxRecords: 4);
      addTearDown(reader.close);
      expect(reader.get('same'), [1]);
      reader.close();
      expect(
        Directory('$path.generations')
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (f) => f.path
                  .split(Platform.pathSeparator)
                  .last
                  .startsWith('lease-'),
            ),
        isEmpty,
      );
    },
  );

  test('unknown ownership retains files and bounds failed maintenance', () {
    final writer = IndexedBlobStore(path, maxRecords: 2);
    addTearDown(writer.close);
    addTearDown(writer.close);
    expect(writer.put('a', Uint8List.fromList([1])), isTrue);
    expect(writer.put('b', Uint8List.fromList([2])), isTrue);
    final orphan = Directory('$path.generations/${'b' * 32}')..createSync();
    final unknown = File('${orphan.path}/lease-$pid-unknown')
      ..writeAsBytesSync([]);
    for (var i = 0; i < 20; i++) {
      expect(writer.put('new', Uint8List.fromList([3])), isFalse);
    }
    expect(generations().length, 2);
    expect(unknown.existsSync(), isTrue);
    expect(writer.get('a'), [1]);
    unknown.deleteSync();
    expect(writer.put('new', Uint8List.fromList([3])), isTrue);
    expect(writer.get('new'), [3]);
    expect(generations().length, 1);
  });

  test('read-only pack fails softly and resumes after permissions recover', () {
    final writer = IndexedBlobStore(path);
    addTearDown(writer.close);
    expect(writer.put('old', Uint8List.fromList([1])), isTrue);
    writer.close();
    final generation = generations().single;
    final files = ['${generation.path}/data', '${generation.path}/data.index'];
    expect(Process.runSync('chmod', ['0444', ...files]).exitCode, 0);
    final reader = IndexedBlobStore(path);
    addTearDown(reader.close);
    try {
      expect(reader.get('old'), isNull);
      expect(reader.put('new', Uint8List.fromList([2])), isFalse);
    } finally {
      expect(Process.runSync('chmod', ['0644', ...files]).exitCode, 0);
    }
    expect(reader.put('new', Uint8List.fromList([2])), isTrue);
    expect(reader.get('new'), [2]);
    reader.close();
  }, skip: Platform.isWindows ? 'POSIX permission modes' : false);

  test('failed pointer publication misses and resumes after repair', () {
    final writer = IndexedBlobStore(path, maxRecords: 2);
    addTearDown(writer.close);
    expect(writer.put('old', Uint8List.fromList([1])), isTrue);
    expect(writer.put('full', Uint8List.fromList([2])), isTrue);
    File('$path.generations/current').deleteSync();
    final blocked = Directory('$path.generations/current')..createSync();
    for (var i = 0; i < 10; i++) {
      expect(writer.put('new', Uint8List.fromList([3])), isFalse);
      expect(writer.get('new'), isNull);
      // The former current, failed replacement and blocking pointer directory
      // may remain until the next retry performs reclamation.
      expect(generations().length, lessThanOrEqualTo(3));
    }
    blocked.deleteSync();
    expect(writer.put('new', Uint8List.fromList([3])), isTrue);
    expect(writer.get('new'), [3]);
    writer.close();
    final reader = IndexedBlobStore(path, maxRecords: 2);
    addTearDown(reader.close);
    expect(reader.get('new'), [3]);
    reader.close();
  });

  test('unavailable generation root is a cache miss', () {
    File('$path.generations').writeAsStringSync('block directory creation');
    final store = IndexedBlobStore(path);
    addTearDown(store.close);
    expect(store.get('key'), isNull);
    expect(store.put('key', Uint8List(1)), isFalse);
    store.close();
  });
}
