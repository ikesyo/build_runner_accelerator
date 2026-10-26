import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:build_runner_accelerator/src/release_cache.dart';
import 'package:build_runner_accelerator/src/release_manifest.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

const _sha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('target lock', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('release-cache-lock-');
    });
    tearDown(() => root.delete(recursive: true));

    Future<void> withLock(
      List<_LockHandle> handles, {
      Duration timeout = const Duration(seconds: 2),
      Future<void> Function()? action,
    }) {
      final file = _LockFile(root, handles);
      return IOOverrides.runZoned(
        () =>
            ReleaseArtifactCache(
              cacheDirectory: root.path,
              lockTimeout: timeout,
            ).withTargetLock(
              version: '1.0.0',
              target: 'test-target',
              action: action ?? () async => fail('action ran without a lock'),
            ),
        createFile: (_) => file,
      );
    }

    final contentionCodes = switch (Platform.operatingSystem) {
      'linux' => [11, 13],
      'macos' => [35, 13],
      'windows' => [33],
      _ => <int>[],
    };
    for (final code in contentionCodes) {
      test('retries contention ($code) and holds the acquired lock', () async {
        final failed = _LockHandle(error: _lockError(code));
        final acquired = _LockHandle();
        await withLock(
          [failed, acquired],
          action: () async {
            expect(failed.attempts, 1);
            expect(failed.closes, 1);
            expect(failed.unlocks, 0);
            expect(acquired.attempts, 1);
            expect(acquired.closes, 0);
            expect(acquired.unlocks, 0);
          },
        );
        expect(acquired.unlocks, 1);
        expect(acquired.closes, 1);
      });

      test(
        'times out persistent contention ($code) and closes attempts',
        () async {
          final handles = <_LockHandle>[];
          // Each open gets a new handle; enough failures to exceed the timeout.
          for (var i = 0; i < 10; i++) {
            handles.add(_LockHandle(error: _lockError(code)));
          }
          await expectLater(
            withLock(handles, timeout: const Duration(milliseconds: 150)),
            throwsA(
              isA<ReleaseDownloadException>().having(
                (error) => error.message,
                'message',
                contains('timed out waiting for release cache lock'),
              ),
            ),
          );
          expect(
            handles.where((handle) => handle.attempts > 0).length,
            greaterThan(1),
          );
          for (final handle in handles) {
            expect(handle.closes, handle.attempts);
            expect(handle.unlocks, 0);
          }
        },
      );
    }

    for (final error in [
      for (final code in [5, 9, 11, 13, 22, 33, 35, 37, 38, 50, 95, 9999])
        if (!contentionCodes.contains(code)) _lockError(code),
      const FileSystemException('no OS error'),
      StateError('unexpected lock failure'),
    ]) {
      test('propagates $error without retry and closes the handle', () async {
        final stack = StackTrace.fromString('original lock failure');
        final handle = _LockHandle(error: error, stack: stack);
        try {
          await withLock([handle]);
          fail('expected lock failure');
        } on Object catch (actual, actualStack) {
          expect(actual, same(error));
          expect(actualStack.toString(), stack.toString());
        }
        expect(handle.attempts, 1);
        expect(handle.closes, 1);
        expect(handle.unlocks, 0);
      });
    }

    test('preserves the lock failure if closing also fails', () async {
      final error = _lockError(5);
      final stack = StackTrace.fromString('original lock failure');
      final handle = _LockHandle(
        error: error,
        stack: stack,
        closeError: _lockError(9),
      );
      try {
        await withLock([handle]);
        fail('expected lock failure');
      } on Object catch (actual, actualStack) {
        expect(actual, same(error));
        expect(actualStack.toString(), stack.toString());
      }
      expect(handle.attempts, 1);
      expect(handle.closes, 1);
    });

    test('releases the acquired lock when the action fails', () async {
      final handle = _LockHandle();
      final error = StateError('action failed');
      await expectLater(
        withLock([handle], action: () async => throw error),
        throwsA(same(error)),
      );
      expect(handle.attempts, 1);
      expect(handle.unlocks, 1);
      expect(handle.closes, 1);
    });
  });

  test('derives the platform archive filename', () {
    expect(
      ReleaseArtifactCache.archiveFilename('linux-x64'),
      'build_runner_accelerator-linux-x64.tar.gz',
    );
    expect(
      ReleaseArtifactCache.archiveFilename('windows-arm64'),
      'build_runner_accelerator-windows-arm64.zip',
    );
  });

  test('rejects path components that could escape the release cache', () {
    expect(
      () => ReleaseArtifactCache.validatePathComponent('../cache', 'target'),
      throwsA(isA<ReleaseDownloadException>()),
    );
    expect(
      () => ReleaseArtifactCache.validatePathComponent('linux/x64', 'target'),
      throwsA(isA<ReleaseDownloadException>()),
    );
  });

  test(
    'uses a crypto fallback when the platform hash tool is unavailable',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'build-runner-accelerator-cache-metadata-test-',
      );
      addTearDown(() => cache.delete(recursive: true));

      const version = '0.3.0';
      const target = 'linux-x64';
      const binaryName = 'build_runner_accelerator';
      final targetDirectory = Directory('${cache.path}/$version/$target');
      await targetDirectory.create(recursive: true);
      final binary = File('${targetDirectory.path}/$binaryName');
      final bytes = utf8.encode('frontend');
      await binary.writeAsBytes(bytes);
      final binaryDigest = crypto.sha256.convert(bytes).toString();
      await File('${targetDirectory.path}/artifact.json').writeAsString(
        jsonEncode({
          'schema_version': 1,
          'package_version': version,
          'target': target,
          'binary': binaryName,
          'archive': 'build_runner_accelerator-linux-x64.tar.gz',
          'archive_size': 1,
          'archive_sha256': _sha256,
          'binary_sha256': binaryDigest,
        }),
      );

      final cached = await ReleaseCacheMetadata.validBinary(
        cacheDirectory: cache.path,
        version: version,
        target: target,
        binaryName: binaryName,
        digestReader: (_) async => null,
        fallbackDigest: (_) async => binaryDigest,
      );
      expect(cached, binary.absolute.path);

      final invalid = await ReleaseCacheMetadata.validBinary(
        cacheDirectory: cache.path,
        version: version,
        target: target,
        binaryName: binaryName,
        digestReader: (_) async => List.filled(64, 'f').join(),
        fallbackDigest: (_) async => binaryDigest,
      );
      expect(invalid, isNull);
    },
  );

  test('extracts the uniquely matching binary from a zip archive', () {
    final bytes = utf8.encode('frontend');
    final archive = Archive()
      ..addFile(
        ArchiveFile('linux-x64/build_runner_accelerator', bytes.length, bytes),
      );
    final archiveBytes = ZipEncoder().encode(archive);

    expect(
      ReleaseArtifactCache.extractBinary(
        archiveBytes,
        archiveFilename: 'build_runner_accelerator-linux-x64.zip',
        binaryName: 'build_runner_accelerator',
      ),
      bytes,
    );
  });

  test('rejects an archive without exactly one matching binary', () {
    final archive = Archive()
      ..addFile(ArchiveFile('README', 1, [1]))
      ..addFile(ArchiveFile('other', 1, [2]));
    final archiveBytes = ZipEncoder().encode(archive);

    expect(
      () => ReleaseArtifactCache.extractBinary(
        archiveBytes,
        archiveFilename: 'build_runner_accelerator-linux-x64.zip',
        binaryName: 'build_runner_accelerator',
      ),
      throwsA(isA<ReleaseDownloadException>()),
    );
  });
}

FileSystemException _lockError(int code) =>
    FileSystemException('lock failed', '', OSError('probe', code));

class _LockHandle implements RandomAccessFile {
  _LockHandle({this.error, this.stack, this.closeError});

  final Object? error;
  final StackTrace? stack;
  final Object? closeError;
  int attempts = 0;
  int closes = 0;
  int unlocks = 0;

  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async {
    expect(mode, FileLock.exclusive);
    attempts++;
    if (error != null) {
      Error.throwWithStackTrace(error!, stack ?? StackTrace.current);
    }
    return this;
  }

  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) async {
    unlocks++;
    return this;
  }

  @override
  Future<void> close() async {
    closes++;
    if (closeError != null) throw closeError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _LockFile implements File {
  _LockFile(this.parent, this.handles);

  @override
  final Directory parent;
  final List<_LockHandle> handles;
  int opens = 0;

  @override
  String get path => '${parent.path}/.test-target.lock';

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    expect(mode, FileMode.append);
    if (opens > 0) expect(handles[opens - 1].closes, 1);
    return handles[opens++];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
