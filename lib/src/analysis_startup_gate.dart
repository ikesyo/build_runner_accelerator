import 'dart:async';
import 'dart:io';

import 'cache_file_lock.dart';
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
  Future<CacheFileLock?>? _acquiring;
  CacheFileLock? _handle;
  int _leases = 0;

  Future<AnalysisStartupLease?> acquire({
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (_ready) return null;
    _leases++;
    final pending = _acquiring ??= _acquire(timeout);
    CacheFileLock? handle;
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

  Future<CacheFileLock?> _acquire(Duration timeout) async {
    CacheFileLock? handle;
    try {
      final file = File(lockPath);
      await file.parent.create(recursive: true);
      handle = await lockCacheFile(
        file,
        timeout: timeout,
        isContention: (error) => isSdkSummaryLockContention(
          error,
          operatingSystem: Platform.operatingSystem,
        ),
        retryDelay: (_) => const Duration(milliseconds: 25),
      );
      // Check only after taking ownership: the previous owner may still be
      // writing its first library even if some linked entries already exist.
      if (isWarm()) {
        await releaseCacheFileLock(handle);
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
        _handle?.release();
      } on FileSystemException {
        // Releasing an optional optimization must not fail an action.
      }
      _handle = null;
      _acquiring = null;
    }
  }

  static Future<void> _close(CacheFileLock? handle) async {
    try {
      await releaseCacheFileLock(handle);
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
