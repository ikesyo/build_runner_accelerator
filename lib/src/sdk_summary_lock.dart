import 'dart:async';
import 'dart:io';

// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/sdk_summary.dart';
import 'package:path/path.dart' as p;

/// Outcome of one [sharedSdkSummaryPath] resolution, including the timings the
/// worker's resolver diagnostics report.
class SdkSummaryResult {
  const SdkSummaryResult(
    this.path, {
    required this.lockWaitUs,
    required this.generatorUs,
  });

  /// The resolved `.dart_tool/build_resolvers/sdk.sum` path.
  final String path;

  /// Microseconds spent waiting for another process's lock.
  final int lockWaitUs;

  /// Microseconds inside [defaultSdkSummaryGenerator] itself.
  final int generatorUs;
}

/// Resolve the SDK summary path while concurrent worker/prewarm processes
/// build it at most once.
///
/// On a cold workspace every process would otherwise run
/// [defaultSdkSummaryGenerator]'s multi-second `buildSdkSummary` call itself:
/// the cached `.dart_tool/build_resolvers/sdk.sum` does not exist yet, so all
/// of them duplicate the work and then race the same rename. The first
/// process to notice the missing summary takes a lock file and builds it;
/// losers wait for the lock release and then take the generator's own
/// cache-hit path. Waiting is bounded; a crashed builder's stale lock is
/// deleted after [_summaryLockMaxAge] so a later run never waits on it.
///
/// The same lock guards the `prewarm_analysis` shards, so a shard already
/// building the summary in the compile window also satisfies worker startup.
Future<SdkSummaryResult> sharedSdkSummaryPath() async {
  final summaryFile = File(p.join('.dart_tool', 'build_resolvers', 'sdk.sum'));
  final lockFile = File(
    p.join('.dart_tool', 'build_resolvers', '.sdk-summary.lock'),
  );

  var ownsLock = false;
  if (!summaryFile.existsSync()) {
    try {
      await lockFile.parent.create(recursive: true);
      lockFile.createSync(exclusive: true);
      ownsLock = true;
    } on FileSystemException {
      // Another process is already building it; wait below.
    }
  }
  var lockWait = Duration.zero;
  if (!ownsLock && lockFile.existsSync()) {
    const step = Duration(milliseconds: 250);
    const maxWait = Duration(minutes: 3);
    final stopwatch = Stopwatch()..start();
    while (lockFile.existsSync()) {
      if (stopwatch.elapsed >= maxWait) break;
      final age = DateTime.now().difference(lockFile.lastModifiedSync());
      if (age > _summaryLockMaxAge) {
        // The builder was killed without releasing; reclaim it.
        try {
          lockFile.deleteSync();
        } on FileSystemException {
          // Still present or already gone — either way, retry owning below.
        }
        if (!summaryFile.existsSync()) {
          try {
            lockFile.createSync(exclusive: true);
            ownsLock = true;
            break;
          } on FileSystemException {
            // Another process reclaimed it first.
          }
        }
      }
      await Future<void>.delayed(step);
    }
    lockWait = stopwatch.elapsed;
  }
  final generatorStopwatch = Stopwatch()..start();
  try {
    final path = await defaultSdkSummaryGenerator();
    return SdkSummaryResult(
      path,
      lockWaitUs: lockWait.inMicroseconds,
      generatorUs: generatorStopwatch.elapsedMicroseconds,
    );
  } finally {
    if (ownsLock) {
      try {
        lockFile.deleteSync();
      } on FileSystemException {
        // Best effort; a leftover lock is reclaimed by the age check above.
      }
    }
  }
}

/// How old a `.sdk-summary.lock` may be before a process treats it as
/// abandoned by a killed builder.
const _summaryLockMaxAge = Duration(minutes: 2);
