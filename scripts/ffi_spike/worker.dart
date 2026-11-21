import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/cache_file_lock.dart';
import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:build_runner_accelerator/src/worker.dart' as worker;

import 'bindings.dart';

Future<void> runWorker({
  required Map<String, BuilderFactory> catalog,
  worker.SharedPartEncoder? sharedPartEncoder,
  worker.SharedPartStepFactory? sharedPartStepFactory,
  required List<String> arguments,
  required Map<String, PostProcessBuilderFactory> postProcessCatalog,
}) async {
  final native = SpikeBindings(arguments[0]);
  final workerId = int.parse(arguments[1]);
  if (Platform.isLinux) {
    cacheLockBackend = (path) => native.lockCache(workerId, path);
  }
  final directRead =
      Platform.environment['BUILD_RUNNER_ACCELERATOR_FFI_DIRECT_READ'] == '1';
  final frames = directRead ? null : StreamController<List<int>>();
  Completer<void>? pendingRead;
  final profiling =
      Platform.environment['BUILD_RUNNER_ACCELERATOR_METRICS'] == '1';
  final readClock = profiling ? Stopwatch() : null;
  final writeClock = profiling ? Stopwatch() : null;
  final decodeClock = profiling ? Stopwatch() : null;
  var notifications = 0;
  Uint8List? receiveFrame() {
    readClock?.start();
    try {
      return native.receiveFrame(workerId);
    } finally {
      readClock?.stop();
    }
  }

  void drain() {
    notifications++;
    if (frames == null) {
      final pending = pendingRead;
      pendingRead = null;
      pending?.complete();
      return;
    }
    if (frames.isClosed) return;
    var frame = receiveFrame();
    while (frame != null) {
      frames.add(frame);
      frame = receiveFrame();
    }
    if (native.finished(workerId) != 0) unawaited(frames.close());
  }

  Future<Uint8List?> readCompleteFrame() async {
    while (true) {
      final frame = receiveFrame();
      if (frame != null || native.finished(workerId) != 0) return frame;
      // Dart callbacks run on this isolate. A notification cannot run
      // between the empty-queue checks and registration of this future.
      final pending = pendingRead ??= Completer<void>();
      await pending.future;
    }
  }

  final notification = NativeCallable<WorkerNotification>.listener(drain);
  try {
    if (native.attach(workerId, notification.nativeFunction) != 0) {
      throw StateError(
        'Could not attach the Dart isolate to the Rust worker connection',
      );
    }
    if (profiling) stderr.writeln('FFI worker attached: worker=$workerId');
    if (!directRead) drain();
    await worker.runWorker(
      catalog: catalog,
      sharedPartEncoder: sharedPartEncoder,
      sharedPartStepFactory: sharedPartStepFactory,
      postProcessCatalog: postProcessCatalog,
      frameReader: frames == null
          ? FrameReader.completeFrames(
              readCompleteFrame,
              decodeClock: decodeClock,
            )
          : FrameReader(frames.stream, decodeClock: decodeClock),
      frameWriter: FrameWriter.withFrameSink((chunks) async {
        writeClock?.start();
        final size = chunks.fold(0, (length, chunk) => length + chunk.length);
        final data = native.alloc(size);
        final buffer = data.asTypedList(size);
        var offset = 0;
        for (final chunk in chunks) {
          buffer.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        writeClock?.stop();
        if (native.send(workerId, data, size) != 0) {
          throw StateError('Rust worker connection closed');
        }
      }),
    );
  } finally {
    if (profiling) {
      stderr.writeln(
        'FFI worker: worker=$workerId notifications=$notifications '
        'take_copy_us=${readClock!.elapsedMicroseconds} '
        'frame_prepare_us=${writeClock!.elapsedMicroseconds} '
        'decode_us=${decodeClock!.elapsedMicroseconds}',
      );
    }
    native.detach(workerId);
    notification.close();
    if (frames != null) unawaited(frames.close());
  }
}
