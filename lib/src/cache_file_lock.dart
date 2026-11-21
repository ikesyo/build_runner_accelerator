import 'dart:io';

/// A whole-file, nonblocking exclusive lock. The owner releases it once.
abstract interface class CacheFileLock {
  void release();
}

/// Failure after opening the descriptor, distinct from an open failure.
class CacheLockException extends FileSystemException {
  CacheLockException(String path, OSError? error)
    : super('Cannot lock cache file', path, error);
}

typedef CacheLockBackend = CacheFileLock Function(String path);

/// The experimental in-process worker installs its backend per isolate.
/// Every cache user in that host process must use the same backend so an
/// isolate can safely probe a lease created by another isolate with its PID.
/// Ordinary workers continue to use Dart's operating-system file locks.
CacheLockBackend? cacheLockBackend;

CacheFileLock lockCacheFileSync(String path, {RandomAccessFile? handle}) {
  final backend = cacheLockBackend;
  if (backend != null) return backend(path);

  final file = handle ?? File(path).openSync(mode: FileMode.append);
  try {
    file.lockSync(FileLock.exclusive);
    return _DartLock(file, owned: handle == null);
  } on FileSystemException catch (error) {
    if (handle == null) file.closeSync();
    throw CacheLockException(path, error.osError);
  }
}

/// Retry nonblocking contention without tying up the isolate's event loop.
Future<CacheFileLock> lockCacheFile(
  File file, {
  required Duration timeout,
  required bool Function(FileSystemException) isContention,
  required Duration Function(Duration) retryDelay,
}) async {
  final timer = Stopwatch()..start();
  final backend = cacheLockBackend;
  final handle = backend == null
      ? await file.open(mode: FileMode.append)
      : null;
  try {
    while (true) {
      try {
        if (handle != null) {
          await handle.lock(FileLock.exclusive);
          return _DartLock(handle, owned: true);
        }
        return backend!(file.path);
      } on FileSystemException catch (error) {
        if ((backend != null && error is! CacheLockException) ||
            !isContention(error) ||
            timer.elapsed >= timeout) {
          rethrow;
        }
        await Future<void>.delayed(retryDelay(timer.elapsed));
      }
    }
  } catch (_) {
    await handle?.close();
    rethrow;
  }
}

Future<void> releaseCacheFileLock(CacheFileLock? lock) async {
  if (lock case _DartLock(_file: final file, _owned: true)) {
    await file.close();
  } else {
    lock?.release();
  }
}

final class _DartLock implements CacheFileLock {
  _DartLock(this._file, {required bool owned}) : _owned = owned;

  final RandomAccessFile _file;
  final bool _owned;

  @override
  void release() {
    if (_owned) {
      _file.closeSync();
    } else {
      _file.unlockSync();
    }
  }
}
