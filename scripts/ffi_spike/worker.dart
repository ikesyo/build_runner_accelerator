import 'dart:async';
import 'dart:ffi';

import 'package:build/build.dart';
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
  final native = SpikeBindings(arguments.single);
  final frames = StreamController<List<int>>();
  void drain() {
    if (frames.isClosed) return;
    var frame = native.receiveFrame();
    while (frame != null) {
      frames.add(frame);
      frame = native.receiveFrame();
    }
    if (native.finished() != 0) unawaited(frames.close());
  }

  final notification = NativeCallable<WorkerNotification>.listener(drain);
  try {
    if (native.attach(notification.nativeFunction) != 0) {
      throw StateError(
        'Could not attach the Dart isolate to the Rust worker connection',
      );
    }
    drain();
    await worker.runWorker(
      catalog: catalog,
      sharedPartEncoder: sharedPartEncoder,
      sharedPartStepFactory: sharedPartStepFactory,
      postProcessCatalog: postProcessCatalog,
      frameReader: FrameReader(frames.stream),
      frameWriter: FrameWriter.withFrameSink((chunks) async {
        final size = chunks.fold(0, (length, chunk) => length + chunk.length);
        final data = native.alloc(size);
        final buffer = data.asTypedList(size);
        var offset = 0;
        for (final chunk in chunks) {
          buffer.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        if (native.send(data, size) != 0) {
          throw StateError('Rust worker connection closed');
        }
      }),
    );
  } finally {
    native.detach();
    notification.close();
    unawaited(frames.close());
  }
}
