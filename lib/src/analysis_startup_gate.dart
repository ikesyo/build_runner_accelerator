import 'dart:async';
import 'dart:io';

import 'sdk_summary_lock.dart' show isSdkSummaryLockContention;

/// Cold linking calls own the cache until their analysis completes.
///
/// Keep one gate per cache fingerprint in an isolate. POSIX locks are per
/// process; sharing the acquisition and reference-counting leases also permits
/// nested optional builders to use the same owner without waiting on themselves.
class AnalysisStartupGate {
  AnalysisStartupGate(this.lockPath, {required this.isWarm});

  final String lockPath;
  final bool Function() isWarm;
  bool _ready = false;
  bool get isReady => _ready;
  Future<RandomAccessFile?>? _acquiring;
  RandomAccessFile? _handle;
  int _leases = 0;

  Future<AnalysisStartupLease?> acquire({
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (_ready) return null;
    _leases++;
    final pending = _acquiring ??= _acquire(timeout);
    RandomAccessFile? handle;
    try {
      handle = await pending;
    } catch (_) {
      if (--_leases == 0) _acquiring = null;
      rethrow;
    }
    if (handle == null) {
      _leases--;
      return null;
    }
    return AnalysisStartupLease._(this);
  }

  Future<RandomAccessFile?> _acquire(Duration timeout) async {
    RandomAccessFile? handle;
    final timer = Stopwatch()..start();
    try {
      final file = File(lockPath);
      await file.parent.create(recursive: true);
      handle = await file.open(mode: FileMode.append);
      while (true) {
        try {
          await handle.lock(FileLock.exclusive);
          break;
        } on FileSystemException catch (error) {
          if (!isSdkSummaryLockContention(
                error,
                operatingSystem: Platform.operatingSystem,
              ) ||
              timer.elapsed >= timeout) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
      // Check only after taking ownership: the previous owner may still be
      // writing its first library even if some linked entries already exist.
      if (isWarm()) {
        await handle.close();
        _ready = true;
        return null;
      }
      _handle = handle;
      return handle;
    } on FileSystemException {
      await _close(handle);
      // Cache locking is best-effort, like cache reads and writes. Avoid
      // repeatedly timing out on subsequent actions if locking is unavailable.
      _ready = true;
      return null;
    } catch (_) {
      await _close(handle);
      rethrow;
    }
  }

  void _release() {
    if (--_leases != 0) return;
    try {
      _ready = isWarm();
    } on FileSystemException {
      _ready = false;
    } finally {
      try {
        _handle?.closeSync();
      } on FileSystemException {
        // Releasing an optional optimization must not fail an action.
      }
      _handle = null;
      _acquiring = null;
    }
  }

  static Future<void> _close(RandomAccessFile? handle) async {
    try {
      await handle?.close();
    } on FileSystemException {
      // A failed lock/open may already have closed the descriptor.
    }
  }
}

class AnalysisStartupLease {
  AnalysisStartupLease._(this._gate);
  AnalysisStartupGate? _gate;

  void release() {
    final gate = _gate;
    _gate = null;
    gate?._release();
  }
}
