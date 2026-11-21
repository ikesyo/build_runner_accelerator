import 'dart:ffi';
import 'dart:typed_data';

typedef HostNotification = Void Function(Int32);
typedef WorkerNotification = Void Function();

class SpikeBindings {
  SpikeBindings(String path) : _library = DynamicLibrary.open(path);

  final DynamicLibrary _library;
  late final alloc = _library
      .lookupFunction<
        Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)
      >('bra_spike_alloc');
  late final free = _library
      .lookupFunction<
        Void Function(Pointer<Uint8>, IntPtr),
        void Function(Pointer<Uint8>, int)
      >('bra_spike_free');
  late final start = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Uint8>,
          IntPtr,
          Pointer<NativeFunction<HostNotification>>,
        ),
        int Function(
          Pointer<Uint8>,
          int,
          Pointer<NativeFunction<HostNotification>>,
        )
      >('bra_spike_start');
  late final attach = _library
      .lookupFunction<
        Int32 Function(Pointer<NativeFunction<WorkerNotification>>),
        int Function(Pointer<NativeFunction<WorkerNotification>>)
      >('bra_spike_attach');
  late final detach = _library.lookupFunction<Void Function(), void Function()>(
    'bra_spike_detach',
  );
  late final _take = _library
      .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
        'bra_spike_take',
      );
  late final finished = _library
      .lookupFunction<Int32 Function(), int Function()>('bra_spike_finished');
  late final send = _library
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, IntPtr),
        int Function(Pointer<Uint8>, int)
      >('bra_spike_send');

  Uint8List? receiveFrame() {
    final data = _take();
    if (data == nullptr) return null;
    final size = 4 + ByteData.sublistView(data.asTypedList(4)).getUint32(0);
    try {
      return Uint8List.fromList(data.asTypedList(size));
    } finally {
      free(data, size);
    }
  }
}
