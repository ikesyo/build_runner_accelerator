import 'package:build_runner_accelerator/src/launcher.dart';
import 'package:test/test.dart';

void main() {
  test('defaults to auto build and forwards the Rust contract', () {
    final options = LauncherOptions.parse(const []);

    expect(options.command, 'build');
    expect(options.mode, 'auto');
    expect(
      options.rustArguments,
      containsAll(<String>['build', '--mode', 'auto']),
    );
    expect(
      options.dartArguments,
      containsAll(<String>[
        'run',
        'build_runner',
        'build',
        '--delete-conflicting-outputs',
      ]),
    );
  });

  test(
    'consumes launcher options and preserves stock build_runner options',
    () {
      final options = LauncherOptions.parse(const [
        'watch',
        '--mode',
        'dart',
        '--root',
        '/tmp/example',
        '--jobs',
        '2',
        '--verbose',
      ]);

      expect(options.command, 'watch');
      expect(options.mode, 'dart');
      expect(options.root, '/tmp/example');
      expect(options.rustArguments, containsAll(<String>['--jobs', '2']));
      expect(options.dartArguments, [
        'run',
        'build_runner',
        'watch',
        '--verbose',
      ]);
    },
  );

  test('rejects an invalid mode', () {
    expect(
      () => LauncherOptions.parse(const ['--mode', 'native']),
      throwsFormatException,
    );
  });

  test('preserves stock AOT mode flags and rejects conflicting modes', () {
    final aot = LauncherOptions.parse(const ['build', '--force-aot']);
    expect(aot.forceAot, isTrue);
    expect(aot.forceJit, isFalse);
    expect(aot.dartArguments, contains('--force-aot'));

    final jit = LauncherOptions.parse(const ['build', '--force-jit']);
    expect(jit.forceAot, isFalse);
    expect(jit.forceJit, isTrue);
    expect(jit.dartArguments, contains('--force-jit'));

    expect(
      () =>
          LauncherOptions.parse(const ['build', '--force-aot', '--force-jit']),
      throwsFormatException,
    );
  });
}
