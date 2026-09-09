import 'package:build_runner_accelerator/launcher.dart';
import 'package:test/test.dart';

void main() {
  test('defaults to auto build and forwards the Rust contract', () {
    final options = LauncherOptions.parse(const []);

    expect(options.command, 'build');
    expect(options.mode, 'auto');
    expect(
      options.rustArguments,
      containsAll(<String>['build', '--mode', 'rust']),
    );
    expect(
      options.dartArguments,
      containsAll(<String>['build', '--delete-conflicting-outputs']),
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
      expect(options.dartArguments, ['watch', '--verbose']);
    },
  );

  test('rejects an invalid mode', () {
    expect(
      () => LauncherOptions.parse(const ['--mode', 'native']),
      throwsFormatException,
    );
  });
}
