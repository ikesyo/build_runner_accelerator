import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/cache_file_lock.dart';

typedef HostNotification = Void Function(Int32, Uint64);
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
        Int32 Function(Uint64, Pointer<NativeFunction<WorkerNotification>>),
        int Function(int, Pointer<NativeFunction<WorkerNotification>>)
      >('bra_spike_attach');
  late final detach = _library
      .lookupFunction<Void Function(Uint64), void Function(int)>(
        'bra_spike_detach',
      );
  late final _take = _library
      .lookupFunction<
        Pointer<Uint8> Function(Uint64),
        Pointer<Uint8> Function(int)
      >('bra_spike_take');
  late final finished = _library
      .lookupFunction<Int32 Function(Uint64), int Function(int)>(
        'bra_spike_finished',
      );
  late final send = _library
      .lookupFunction<
        Int32 Function(Uint64, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('bra_spike_send');

  late final _lock = _library
      .lookupFunction<
        Int64 Function(Uint64, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('bra_spike_cache_lock');
  late final _unlock = _library
      .lookupFunction<Void Function(Uint64, Int64), void Function(int, int)>(
        'bra_spike_cache_unlock',
      );
  late final releaseWorkerLocks = _library
      .lookupFunction<Void Function(Uint64), void Function(int)>(
        'bra_spike_release_worker_locks',
      );

  CacheFileLock lockCache(int worker, String path) {
    final bytes = utf8.encode(path);
    final data = alloc(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final token = _lock(worker, data, bytes.length);
    if (token >= 0) return _WorkerCacheLock(() => _unlock(worker, token));
    const openError = 4096;
    if (token < -openError) {
      throw FileSystemException(
        'Cannot open cache lock file',
        path,
        OSError('', -token - openError),
      );
    }
    throw CacheLockException(path, OSError('', -token));
  }

  Uint8List? receiveFrame(int workerId) {
    final data = _take(workerId);
    if (data == nullptr) return null;
    final size = 4 + ByteData.sublistView(data.asTypedList(4)).getUint32(0);
    try {
      return Uint8List.fromList(data.asTypedList(size));
    } finally {
      free(data, size);
    }
  }
}

final class _WorkerCacheLock implements CacheFileLock {
  _WorkerCacheLock(this.releaseLock);

  final void Function() releaseLock;

  @override
  void release() => releaseLock();
}
