import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/cache_file_lock.dart';
import 'package:build_runner_accelerator/src/indexed_blob_store.dart';
import 'package:build_runner_accelerator/src/sdk_summary_lock.dart';

import 'bindings.dart';

Future<void> holdLease((String, String, SendPort) args) async {
  final (library, path, port) = args;
  final native = SpikeBindings(library);
  cacheLockBackend = (path) => native.lockCache(2, path);
  final store = IndexedBlobStore(path, maxRecords: 2);
  if (store.get('old')?.single != 1)
    throw StateError('Could not lease old pack');

  await sharedSdkSummaryPath(
    generate: () async {
      final marker = File('summary-in-progress')..writeAsStringSync('isolate');
      port.send('summary started');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      marker.deleteSync();
      return 'sdk.sum';
    },
  );

  final keepAlive = ReceivePort();
  port.send('lease held');
  // The parent terminates this isolate without closing its store.
  await keepAlive.first;
}

Future<void> main(List<String> args) async {
  final library = File(args.single).absolute.path;
  final native = SpikeBindings(library);
  cacheLockBackend = (path) => native.lockCache(1, path);
  final previousDirectory = Directory.current;
  final directory = Directory.systemTemp.createTempSync('bra-ffi-cache-probe-');
  Directory.current = directory;
  final path = '${directory.path}/store.bin';
  final store = IndexedBlobStore(path, maxRecords: 2);
  final events = ReceivePort();
  final replies = StreamIterator(events);
  Isolate? sibling;
  try {
    void put(String key) {
      if (!store.put(key, Uint8List.fromList([1]))) {
        throw StateError('Could not write $key');
      }
    }

    Future<void> expectEvent(Object? expected) async {
      final received = await replies.moveNext().timeout(
        const Duration(seconds: 15),
      );
      if (!received || replies.current != expected) {
        throw StateError('Expected $expected, got ${replies.current}');
      }
    }

    put('old');
    final generations = Directory('$path.generations');
    final original = generations.listSync().whereType<Directory>().single;
    store.close();

    sibling = await Isolate.spawn(
      holdLease,
      (library, path, events.sendPort),
      onExit: events.sendPort,
      onError: events.sendPort,
    );
    await expectEvent('summary started');
    await sharedSdkSummaryPath(
      generate: () async {
        if (File('summary-in-progress').existsSync()) {
          throw StateError('SDK summary lock admitted sibling isolates');
        }
        return 'sdk.sum';
      },
    );
    await expectEvent('lease held');

    put('second');
    put('rotated');
    if (!original.existsSync()) {
      throw StateError('Reclaimed a generation still leased by a sibling');
    }

    sibling.kill(priority: Isolate.immediate);
    await expectEvent(null);
    sibling = null;
    native.releaseWorkerLocks(2);

    put('fourth');
    put('rotated again');
    if (original.existsSync()) {
      throw StateError('Dead isolate retained an old generation');
    }
    stdout.writeln(
      'SDK summary serialized, live lease retained, dead lease reclaimed',
    );
  } finally {
    // Process teardown also closes the native descriptors if the probe fails.
    sibling?.kill(priority: Isolate.immediate);
    await replies.cancel();
    events.close();
    store.close();
    native.releaseWorkerLocks(1);
    Directory.current = previousDirectory;
    directory.deleteSync(recursive: true);
  }
}
