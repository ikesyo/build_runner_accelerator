import 'dart:convert';
import 'dart:ffi' as ffi;

const processGroupCommand = '--accelerator-process-group';

final _libc = ffi.DynamicLibrary.process();
final _setsid = _libc.lookupFunction<ffi.Int32 Function(), int Function()>(
  'setsid',
);
final _kill = _libc
    .lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Int32),
      int Function(int, int)
    >('kill');
final _calloc = _libc
    .lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.IntPtr, ffi.IntPtr),
      ffi.Pointer<ffi.Void> Function(int, int)
    >('calloc');
final _execvp = _libc
    .lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<ffi.Pointer<ffi.Char>>,
      ),
      int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
    >('execvp');
final _free = _libc
    .lookupFunction<
      ffi.Void Function(ffi.Pointer<ffi.Void>),
      void Function(ffi.Pointer<ffi.Void>)
    >('free');

bool signalProcessGroup(int pid, int signal) => _kill(-pid, signal) == 0;

/// A small re-entry path in the source or AOT launcher. Exec keeps the PID
/// registered with Dart's Process API, so stock's status remains unchanged.
Never executeInProcessGroup(String executable, List<String> arguments) {
  if (_setsid() < 0) throw StateError('Cannot create child process session');
  final allocations = <ffi.Pointer<ffi.Void>>[];
  ffi.Pointer<T> allocate<T extends ffi.NativeType>(int count, int size) {
    final pointer = _calloc(count, size);
    if (pointer == ffi.nullptr) throw StateError('Native allocation failed');
    allocations.add(pointer);
    return pointer.cast<T>();
  }

  try {
    final values = [executable, ...arguments];
    final argv = allocate<ffi.Pointer<ffi.Char>>(
      values.length + 1,
      ffi.sizeOf<ffi.Pointer<ffi.Char>>(),
    );
    for (var index = 0; index < values.length; index++) {
      if (values[index].contains('\u0000')) {
        throw ArgumentError('Process arguments cannot contain null bytes');
      }
      final bytes = utf8.encode(values[index]);
      final string = allocate<ffi.Uint8>(bytes.length + 1, 1);
      string.asTypedList(bytes.length).setAll(0, bytes);
      argv[index] = string.cast<ffi.Char>();
    }
    _execvp(argv[0], argv);
    throw StateError('Cannot execute child: $executable');
  } finally {
    for (final allocation in allocations) {
      _free(allocation);
    }
  }
}
