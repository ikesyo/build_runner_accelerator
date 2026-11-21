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
  final native = SpikeBindings(library);
  final engineFinished = Completer<int>();
  final workerFinished = Completer<void>();
  final workerEvents = ReceivePort();
  var workerStarted = false;
  var workerFailed = false;
  final workerSubscription = workerEvents.listen((event) {
    if (event == null) {
      native.detach();
      workerFinished.complete();
    } else {
      workerFailed = true;
      stderr.writeln(
        'Dart worker isolate failed: ${(event as List).join('\n')}',
      );
      native.detach();
    }
  });

  Future<void> spawnWorker() async {
    try {
      await Isolate.spawnUri(
        snapshot,
        [library],
        null,
        onExit: workerEvents.sendPort,
        onError: workerEvents.sendPort,
      );
    } catch (error, stack) {
      workerFailed = true;
      stderr.writeln('Could not start Dart worker isolate: $error\n$stack');
      native.detach();
      workerFinished.complete();
    }
  }

  void onEngineEvent(int event) {
    if (event == 1) {
      workerStarted = true;
      unawaited(spawnWorker());
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
    exitCode = await engineFinished.future;
    if (workerStarted) await workerFinished.future;
    if (workerFailed) exitCode = 1;
  } finally {
    notification.close();
    await workerSubscription.cancel();
    workerEvents.close();
  }
}
