import 'dart:io';

import 'package:test/test.dart';

void main() {
  final source = File('test/sdk_summary_lock_process.dart').absolute.path;
  late Directory artifacts;
  late String script;
  final config = File('.dart_tool/package_config.json').absolute.path;
  late Directory root;
  final children = <Process>[];

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp(
      'sdk-summary-lock-helper-',
    );
    script = '${artifacts.path}/helper.dill';
    final result = await Process.run(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'compile',
      'kernel',
      '--packages=$config',
      '--output=$script',
      source,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sdk-summary-lock-test-');
  });
  tearDown(() async {
    for (final child in children) {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
    }
    children.clear();
    await root.delete(recursive: true);
  });

  Future<Process> start(String mode, String id) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=$config',
      script,
      mode,
      id,
    ], workingDirectory: root.path);
    children.add(process);
    return process;
  }

  Future<void> waitFor(String name) async {
    final timer = Stopwatch()..start();
    while (!File('${root.path}/$name').existsSync()) {
      if (timer.elapsed > const Duration(seconds: 30)) {
        fail('timed out waiting for $name');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> succeeds(Process process) async {
    final stdout = process.stdout.drain<void>();
    final stderr = process.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    expect(
      await process.exitCode.timeout(const Duration(seconds: 45)),
      0,
      reason: await stderr,
    );
    await stdout;
  }

  for (final existing in [false, true]) {
    test(
      'serializes ${existing ? 'invalid cached' : 'cold'} summary generation',
      () async {
        if (existing) File('${root.path}/sdk.sum').writeAsStringSync('invalid');
        final processes = await Future.wait(
          List.generate(4, (i) => start('generate', '$i')),
        );
        await Future.wait(processes.map(succeeds));
        expect(File('${root.path}/generations').readAsLinesSync(), [
          'generated',
        ]);
        expect(
          File(
            '${root.path}/.dart_tool/build_resolvers/.sdk-summary.lock',
          ).existsSync(),
          isTrue,
        );
      },
    );
  }

  test('serializes concurrent calls in one isolate', () async {
    await succeeds(await start('local', 'local'));
    expect(File('${root.path}/generations').readAsLinesSync(), ['generated']);
  });

  test('releases lock and in-flight state when generation fails', () async {
    await succeeds(await start('retry', 'retry'));
    expect(File('${root.path}/sdk.sum').readAsStringSync(), 'valid');
  });

  test('killed holder releases lock immediately', () async {
    final holder = await start('hold', 'holder');
    await waitFor('holding');
    final waiter = await start('generate', 'waiter');
    await waitFor('started-waiter');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(File('${root.path}/sdk.sum').existsSync(), isFalse);
    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode;
    await succeeds(waiter);
  }, skip: Platform.isWindows ? 'uses POSIX process termination' : false);

  test('bounded lock wait falls back to stock generation', () async {
    await start('hold', 'holder');
    await waitFor('holding');
    await succeeds(await start('timeout', 'waiter'));
    expect(File('${root.path}/sdk.sum').readAsStringSync(), 'valid');
  });
}
