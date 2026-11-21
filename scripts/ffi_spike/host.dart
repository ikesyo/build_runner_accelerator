import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'bindings.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: host LIBRARY WORKER_SNAPSHOT BUILD_ARGUMENTS...');
    exitCode = 64;
    return;
  }
  final library = File(args[0]).absolute.path;
  final snapshot = File(args[1]).absolute.uri;
  final clock = Stopwatch()..start();
  final profiling =
      Platform.environment['BUILD_RUNNER_ACCELERATOR_METRICS'] == '1';
  final native = SpikeBindings(library);
  final libraryOpenUs = clock.elapsedMicroseconds;
  final engineFinished = Completer<int>();
  final workers = <Future<bool>>[];

  Future<bool> spawnWorker(int id) async {
    final events = ReceivePort();
    var failed = false;
    try {
      await Isolate.spawnUri(
        snapshot,
        [library, id.toString()],
        null,
        onExit: events.sendPort,
        onError: events.sendPort,
      );
      await for (final event in events) {
        if (event == null) return failed;
        failed = true;
        stderr.writeln(
          'Dart worker isolate $id failed: ${(event as List).join('\n')}',
        );
        native.detach(id);
      }
      return failed;
    } catch (error, stack) {
      stderr.writeln('Could not start Dart worker isolate $id: $error\n$stack');
      return true;
    } finally {
      // The terminal isolate event is the lifetime boundary for native locks.
      if (Platform.isLinux) native.releaseWorkerLocks(id);
      native.detach(id);
      events.close();
    }
  }

  void onEngineEvent(int event, int id) {
    if (event == 1) {
      workers.add(spawnWorker(id));
    } else {
      engineFinished.complete(event == 2 ? 0 : 1);
    }
  }

  final notification = NativeCallable<HostNotification>.listener(onEngineEvent);
  try {
    final encoded = utf8.encode(jsonEncode(args.sublist(2)));
    final data = native.alloc(encoded.length);
    data.asTypedList(encoded.length).setAll(0, encoded);
    if (native.start(data, encoded.length, notification.nativeFunction) != 0) {
      throw StateError('Could not start the Rust engine');
    }
    final submittedUs = clock.elapsedMicroseconds;
    exitCode = await engineFinished.future;
    final engineDoneUs = clock.elapsedMicroseconds;
    if ((await Future.wait(workers)).contains(true)) exitCode = 1;
    if (profiling) {
      stderr.writeln(
        'FFI host: library_open_us=$libraryOpenUs submitted_us=$submittedUs '
        'engine_done_us=$engineDoneUs host_done_us=${clock.elapsedMicroseconds} '
        'workers=${workers.length}',
      );
    }
  } finally {
    notification.close();
  }
}
