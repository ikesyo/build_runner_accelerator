import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:build_runner_accelerator/src/analysis_startup_gate.dart';
import 'package:build_runner_accelerator/src/packed_analysis_byte_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late Directory artifacts;
  late String script;
  final config = File('.dart_tool/package_config.json').absolute.path;
  final children = <Process>[];

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp(
      'analysis-startup-helper-',
    );
    script = '${artifacts.path}/helper.dill';
    final result = await Process.run(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'compile',
      'kernel',
      '--packages=$config',
      '--output=$script',
      File('test/analysis_startup_gate_process.dart').absolute.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDownAll(() => artifacts.delete(recursive: true));
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('analysis-startup-test-');
  });
  tearDown(() async {
    for (final process in children) {
      process.kill();
      await process.exitCode;
    }
    children.clear();
    await dir.delete(recursive: true);
  });

  Future<(Process, StreamQueue<String>)> start({bool timeout = false}) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=$config',
      script,
      dir.path,
      if (timeout) 'timeout',
    ]);
    children.add(process);
    process.stderr.transform(utf8.decoder).listen((text) => fail(text));
    final output = StreamQueue(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    addTearDown(() => output.cancel());
    expect(await output.next.timeout(const Duration(seconds: 30)), 'ready');
    return (process, output);
  }

  Future<void> command(
    (Process, StreamQueue<String>) child,
    String command,
    String expected,
  ) async {
    child.$1.stdin.writeln(command);
    expect(await child.$2.next.timeout(const Duration(seconds: 30)), expected);
  }

  test('waiters see published entries and then run concurrently', () async {
    final owner = await start();
    final waiters = [await start(), await start()];
    await command(owner, 'acquire', 'waiting');
    expect(await owner.$2.next, 'owner');
    await command(owner, 'write', 'written');
    // Even after some entries exist, wait for the owning action to finish.
    for (final waiter in waiters) {
      await command(waiter, 'acquire', 'waiting');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (final waiter in waiters) {
      expect(
        await waiter.$2.hasNext.timeout(
          const Duration(milliseconds: 50),
          onTimeout: () => false,
        ),
        isFalse,
      );
    }
    await command(owner, 'release', 'released');
    for (final waiter in waiters) {
      expect(await waiter.$2.next.timeout(const Duration(seconds: 30)), 'warm');
      await command(waiter, 'read', 'hit');
    }
    // Neither warm waiter holds the lock waiting for an action release.
    final later = await start();
    await command(later, 'acquire', 'waiting');
    expect(await later.$2.next, 'warm');
  });

  test('nested leases share ownership until the last release', () async {
    final store = PackedAnalysisByteStore(dir.path);
    addTearDown(store.close);
    final gate = AnalysisStartupGate(
      '${dir.path}/.analysis-startup.lock',
      isWarm: () => store.hasLinkedEntries,
    );
    final leases = await Future.wait([gate.acquire(), gate.acquire()]);
    expect(leases.every((lease) => lease != null), isTrue);
    store.putGet('library.linked', Uint8List.fromList([42]));
    leases.first!.release();
    leases.first!.release();
    final waiter = await start(timeout: true);
    await command(waiter, 'acquire', 'waiting');
    expect(
      await waiter.$2.next,
      'warm',
    ); // Timeout fallback, owner still holds.
    leases.last!.release();
    expect(await gate.acquire(), isNull);
  });

  test('syntax-only actions leave linking eligible for a new owner', () async {
    final store = PackedAnalysisByteStore(dir.path);
    addTearDown(store.close);
    final gate = AnalysisStartupGate(
      '${dir.path}/.analysis-startup.lock',
      isWarm: () => store.hasLinkedEntries,
    );
    final first = await gate.acquire();
    store.putGet('library.unlinked2', Uint8List.fromList([1]));
    first!.release();
    final second = await gate.acquire();
    expect(second, isNotNull);
    second!.release();
  });

  test(
    'unavailable lock falls back without blocking subsequent actions',
    () async {
      final blocked = File('${dir.path}/not-a-directory')
        ..writeAsStringSync('x');
      final gate = AnalysisStartupGate(
        '${blocked.path}/startup.lock',
        isWarm: () => false,
      );
      expect(await gate.acquire(), isNull);
      expect(await gate.acquire(), isNull);
    },
  );

  test('killed cold owner lets a waiter take over', () async {
    final owner = await start();
    await command(owner, 'acquire', 'waiting');
    expect(await owner.$2.next, 'owner');
    final waiter = await start();
    await command(waiter, 'acquire', 'waiting');
    owner.$1.kill(ProcessSignal.sigkill);
    await owner.$1.exitCode;
    expect(await waiter.$2.next.timeout(const Duration(seconds: 30)), 'owner');
    await command(waiter, 'release', 'released');
  }, skip: Platform.isWindows);

  test(
    'published entries survive an owner killed before close',
    () async {
      final owner = await start();
      final waiter = await start();
      await command(owner, 'acquire', 'waiting');
      expect(await owner.$2.next, 'owner');
      await command(owner, 'write', 'written');
      await command(waiter, 'acquire', 'waiting');
      // No graceful close or explicit flush: completing the write publishes
      // bytes, and process termination releases the startup lock.
      owner.$1.kill(ProcessSignal.sigkill);
      await owner.$1.exitCode;
      expect(await waiter.$2.next.timeout(const Duration(seconds: 30)), 'warm');
      await command(waiter, 'read', 'hit');
    },
    // Uses POSIX process termination.
    skip: Platform.isWindows,
  );
}
