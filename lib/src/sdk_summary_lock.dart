import 'dart:async';
import 'dart:io';

// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/sdk_summary.dart';
import 'package:path/path.dart' as p;

/// Outcome of one [sharedSdkSummaryPath] resolution.
class SdkSummaryResult {
  const SdkSummaryResult(
    this.path, {
    required this.lockWaitUs,
    required this.generatorUs,
  });

  final String path;
  final int lockWaitUs;
  final int generatorUs;
}

// POSIX locks are per process, so also serialize calls within this isolate.
final _pending = <String, Future<SdkSummaryResult>>{};

/// Serialize SDK summary validation and generation across workers and prewarm.
///
/// Always hold the lock while the generator checks its cache: an existing
/// sdk.sum may still need rebuilding after an SDK or dependency change. The OS
/// releases the lock on process exit, including when a prewarm shard is killed.
/// The lock file stays in place so all callers lock the same filesystem object.
/// Lock failures or a bounded timeout fall back to the stock generator.
Future<SdkSummaryResult> sharedSdkSummaryPath({
  Future<String> Function() generate = defaultSdkSummaryGenerator,
  Duration lockTimeout = const Duration(minutes: 3),
}) {
  final lockPath = p.absolute(
    '.dart_tool',
    'build_resolvers',
    '.sdk-summary.lock',
  );
  return _pending.putIfAbsent(lockPath, () {
    return _resolve(lockPath, generate, lockTimeout).whenComplete(() {
      _pending.remove(lockPath);
    });
  });
}

Future<SdkSummaryResult> _resolve(
  String lockPath,
  Future<String> Function() generate,
  Duration lockTimeout,
) async {
  final stopwatch = Stopwatch()..start();
  final lockFile = File(lockPath);
  RandomAccessFile? handle;
  try {
    await lockFile.parent.create(recursive: true);
    final opened = await lockFile.open(mode: FileMode.append);
    handle = opened;
    while (true) {
      try {
        await opened.lock(FileLock.exclusive);
        break;
      } on FileSystemException {
        if (stopwatch.elapsed >= lockTimeout) {
          await opened.close();
          handle = null;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  } on FileSystemException {
    await handle?.close();
    handle = null;
  }
  final lockWaitUs = stopwatch.elapsedMicroseconds;
  final generatorStopwatch = Stopwatch()..start();
  try {
    return SdkSummaryResult(
      await generate(),
      lockWaitUs: lockWaitUs,
      generatorUs: generatorStopwatch.elapsedMicroseconds,
    );
  } finally {
    // Closing the handle releases the lock, without a delete/recreate race.
    await handle?.close();
  }
}
