import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

const String sharedReadMemoryCapability = 'asset-rpc-shared-memory-read-v1';
const String _enabledEnvironment =
    'BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY';
const String _pathEnvironment =
    'BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY_PATH';
const String _capacityEnvironment =
    'BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY_CAPACITY';

typedef _MallocNative = ffi.Pointer<ffi.Void> Function(ffi.IntPtr size);
typedef _Malloc = ffi.Pointer<ffi.Void> Function(int size);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Void> pointer);
typedef _Free = void Function(ffi.Pointer<ffi.Void> pointer);
typedef _OpenNative =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8> path,
      ffi.Int32 flags,
      ffi.Int32 mode,
    );
typedef _Open = int Function(ffi.Pointer<ffi.Uint8> path, int flags, int mode);
typedef _CloseNative = ffi.Int32 Function(ffi.Int32 fd);
typedef _Close = int Function(int fd);
typedef _MmapNative =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void> address,
      ffi.IntPtr length,
      ffi.Int32 protection,
      ffi.Int32 flags,
      ffi.Int32 fd,
      ffi.Int64 offset,
    );
typedef _Mmap =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void> address,
      int length,
      int protection,
      int flags,
      int fd,
      int offset,
    );
typedef _MunmapNative =
    ffi.Int32 Function(ffi.Pointer<ffi.Void> address, ffi.IntPtr length);
typedef _Munmap = int Function(ffi.Pointer<ffi.Void> address, int length);

/// One read-only view of the Rust worker's per-process shared buffer.
///
/// The buffer is intentionally a single slot: the Rust frontend sends one
/// read request at a time to a worker, writes the bytes, and then sends the
/// response header. [read] copies the requested slice before the next request
/// can overwrite it, preserving the existing Dart cache semantics.
final class SharedReadMemory {
  SharedReadMemory._(
    this.libc,
    this._close,
    this._munmap,
    this._mapping,
    this._capacity,
    this._fd,
  );

  static const int _oRdOnly = 0;
  static const int _protRead = 0x1;
  static const int _mapShared = 0x1;

  // Keep the dynamic library handle alive for the lifetime of the native
  // function pointers below.
  final ffi.DynamicLibrary libc;
  final _Close _close;
  final _Munmap _munmap;
  final ffi.Pointer<ffi.Void> _mapping;
  final int _capacity;
  final int _fd;
  bool _disposed = false;

  static SharedReadMemory? fromEnvironment() {
    if (Platform.environment[_enabledEnvironment] != '1') return null;
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError(
        'read shared memory PoC is only available on Linux and macOS',
      );
    }
    final path = Platform.environment[_pathEnvironment];
    if (path == null || path.isEmpty) {
      throw StateError(
        '$_pathEnvironment is required when shared memory is enabled',
      );
    }
    final capacity = _parseCapacity(Platform.environment[_capacityEnvironment]);
    final libc = _openSystemLibrary();
    final malloc = libc.lookupFunction<_MallocNative, _Malloc>('malloc');
    final free = libc.lookupFunction<_FreeNative, _Free>('free');
    final open = libc.lookupFunction<_OpenNative, _Open>('open');
    final close = libc.lookupFunction<_CloseNative, _Close>('close');
    final mmap = libc.lookupFunction<_MmapNative, _Mmap>('mmap');
    final munmap = libc.lookupFunction<_MunmapNative, _Munmap>('munmap');

    final pathBytes = utf8.encode(path);
    final pathPointer = malloc(pathBytes.length + 1).cast<ffi.Uint8>();
    if (pathPointer.address == 0) {
      throw StateError('malloc failed while opening shared read memory');
    }
    try {
      final pathView = pathPointer.asTypedList(pathBytes.length + 1);
      pathView.setAll(0, pathBytes);
      pathView[pathBytes.length] = 0;
      final fd = open(pathPointer, _oRdOnly, 0);
      if (fd < 0) {
        throw OSError('open failed for shared read memory: $path');
      }
      final mapping = mmap(
        ffi.Pointer<ffi.Void>.fromAddress(0),
        capacity,
        _protRead,
        _mapShared,
        fd,
        0,
      );
      if (_isMapFailed(mapping)) {
        close(fd);
        throw OSError('mmap failed for shared read memory: $path');
      }
      return SharedReadMemory._(libc, close, munmap, mapping, capacity, fd);
    } finally {
      free(pathPointer.cast<ffi.Void>());
    }
  }

  Uint8List read(int length) {
    if (_disposed) throw StateError('shared read memory is disposed');
    if (length < 0 || length > _capacity) {
      throw FormatException(
        'shared read length $length exceeds capacity $_capacity',
      );
    }
    // Copy before returning: Rust reuses the one-slot mapping for the next
    // request, while the existing remote reader stores an independent cache.
    return Uint8List.fromList(_mapping.cast<ffi.Uint8>().asTypedList(length));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _munmap(_mapping, _capacity);
    _close(_fd);
  }

  static int _parseCapacity(String? raw) {
    final capacity = raw == null ? 16 * 1024 * 1024 : int.tryParse(raw);
    if (capacity == null || capacity <= 0) {
      throw FormatException('$_capacityEnvironment must be a positive integer');
    }
    return capacity;
  }

  static ffi.DynamicLibrary _openSystemLibrary() {
    // Linux exposes the POSIX calls through glibc; macOS exposes them through
    // the system libSystem shim. Keep this lookup explicit so the default
    // binary IPC path never loads a native library.
    if (Platform.isMacOS) {
      return ffi.DynamicLibrary.open('libSystem.B.dylib');
    }
    return ffi.DynamicLibrary.open('libc.so.6');
  }

  static bool _isMapFailed(ffi.Pointer<ffi.Void> pointer) {
    final maxAddress = (1 << (ffi.sizeOf<ffi.IntPtr>() * 8)) - 1;
    return pointer.address == -1 || pointer.address == maxAddress;
  }
}
