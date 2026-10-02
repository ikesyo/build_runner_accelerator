import 'dart:io';

import 'package:build_runner_accelerator/src/sdk_summary_lock.dart';
import 'package:test/test.dart';

FileSystemException lockError(int code) =>
    FileSystemException('lock failed', '', OSError('probe', code));

class _LockHandle implements RandomAccessFile {
  _LockHandle(this.failures);

  final List<FileSystemException> failures;
  int attempts = 0;
  int closes = 0;

  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async {
    expect(mode, FileLock.exclusive);
    attempts++;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    return this;
  }

  @override
  Future<void> close() async => closes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _LockFile implements File {
  _LockFile(this.parent, this.handle);

  @override
  final Directory parent;
  final _LockHandle handle;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      handle;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test('classifies contention using the operating system', () {
    for (final os in ['linux', 'macos', 'windows', 'unknown']) {
      final expected = switch (os) {
        'linux' => {11, 13},
        'macos' => {35, 13},
        'windows' => {33},
        _ => <int>{},
      };
      for (final code in [5, 9, 11, 13, 22, 33, 35, 37, 38, 50, 95, 9999]) {
        expect(
          isSdkSummaryLockContention(lockError(code), operatingSystem: os),
          expected.contains(code),
          reason: '$os error $code',
        );
      }
      expect(
        isSdkSummaryLockContention(
          const FileSystemException('no OS error'),
          operatingSystem: os,
        ),
        isFalse,
      );
    }
  });

  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sdk-summary-lock-errors-');
  });
  tearDown(() => root.delete(recursive: true));

  for (final error in [
    lockError(5),
    lockError(9999),
    const FileSystemException('no OS error'),
  ]) {
    test('falls back without retrying $error', () async {
      final handle = _LockHandle([error]);
      final result = await IOOverrides.runZoned(
        () => sharedSdkSummaryPath(
          lockTimeout: const Duration(milliseconds: 200),
          generate: () async {
            expect(handle.attempts, 1);
            expect(handle.closes, 1);
            return 'fallback';
          },
        ),
        createFile: (_) => _LockFile(root, handle),
      );
      expect(result.path, 'fallback');
      expect(handle.closes, 1);
    });
  }

  test('retries contention and keeps ownership during generation', () async {
    final code = switch (Platform.operatingSystem) {
      'linux' => 11,
      'macos' => 35,
      'windows' => 33,
      _ => null,
    };
    if (code == null) return;
    final handle = _LockHandle([lockError(code)]);
    final result = await IOOverrides.runZoned(
      () => sharedSdkSummaryPath(
        generate: () async {
          expect(handle.attempts, 2);
          expect(handle.closes, 0);
          return 'locked';
        },
      ),
      createFile: (_) => _LockFile(root, handle),
    );
    expect(result.path, 'locked');
    expect(handle.closes, 1);
  });
}
