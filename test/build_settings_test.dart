import 'package:build_runner/src/build_runner_command_line.dart';
import 'package:build_runner/src/build_plan/build_options.dart';
import 'package:build_runner/src/build_plan/build_paths.dart';
import 'package:build_runner_accelerator/src/manifest/settings.dart';
import 'package:build_runner_accelerator/src/launcher_options.dart';
import 'package:test/test.dart';

void main() {
  test('settings parsing agrees with resolved stock build_runner', () async {
    for (final arguments in <List<String>>[
      [],
      ['--release'],
      ['--no-release'],
      ['--define==x=1', '--define=:=x=2'],
      ['-r', '--no-release', '--release'],
      ['--config', 'one', '-c', 'two', '--config='],
      [
        '--define',
        ':b=text=a=b,c',
        '--define=:b=json={"a":[1,true,null]}',
        '--define=pkg|builder=number=42',
        '--define=:b=empty=',
        '--define=:b==false',
        '--config=named',
        '--release',
      ],
    ]) {
      final native = BuildSettings.parse(arguments);
      final cli = (await BuildRunnerCommandLine.parse([
        'build',
        ...arguments,
      ]))!;
      final stock = BuildOptions.parse(
        cli,
        buildPaths: BuildPaths(packagePath: '.', buildWorkspace: false),
        currentPackage: 'example',
        restIsBuildDirs: true,
      );
      expect(native.release, stock.isReleaseBuild);
      expect(native.config, stock.configKey);
      expect(native.overrides('example'), {
        for (final entry in stock.builderConfigOverrides.entries)
          entry.key: entry.value.asMap(),
      });
    }
  });

  test('duplicate aliases are errors just as in stock', () async {
    final arguments = ['--define=:b=x=1', '--define=example|b=x=2'];
    final cli = (await BuildRunnerCommandLine.parse(['build', ...arguments]))!;
    expect(
      () => BuildOptions.parse(
        cli,
        buildPaths: BuildPaths(packagePath: '.', buildWorkspace: false),
        currentPackage: 'example',
        restIsBuildDirs: true,
      ),
      throwsArgumentError,
    );
    expect(
      () => BuildSettings.parse(arguments).overrides('example'),
      throwsArgumentError,
    );
  });

  test('launcher keeps settings in native and both fallback vectors', () {
    for (final command in [
      'build',
      'watch',
      'prewarm',
      'aot-prewarm',
      'aot-cache-key',
    ]) {
      final flags = ['--config', 'named', '--release', '--define=:b=x=a=b,c'];
      for (final mode in ['auto', 'rust', 'dart']) {
        final options = LauncherOptions.parse([
          command,
          '--mode=$mode',
          ...flags,
        ]);
        expect(options.nativeUnsupported, isFalse);
        expect(options.dartArguments, [
          'run',
          'build_runner',
          command,
          ...flags,
        ]);
        expect(options.rustArguments.last, contains('"--define=:b=x=a=b,c"'));
      }
    }
  });

  test('configuration values do not act as launcher or compile flags', () {
    for (final command in ['build', 'watch', 'prewarm']) {
      final options = LauncherOptions.parse([
        command,
        '--config',
        '--force-aot',
        '--force-jit',
      ]);
      expect(options.nativeUnsupported, isFalse);
      expect(options.forceAot, isFalse);
      expect(options.forceJit, isTrue);
      expect(BuildSettings.parse(['--config', '-d']).deletionFlag, isFalse);
    }
  });

  test('invalid settings select early fallback without losing values', () {
    for (final arguments in <List<String>>[
      ['--define'],
      ['--define=x=y'],
      ['--define=:b=x=1', '--define=:b=x=2'],
      ['--release=true'],
      ['--no-release=false'],
      ['--config'],
      ['--config=../other'],
      ['-cnamed'],
    ]) {
      final options = LauncherOptions.parse(['build', ...arguments]);
      expect(options.nativeUnsupported, isTrue);
      expect(options.dartArguments, [
        'run',
        'build_runner',
        'build',
        ...arguments,
      ]);
      expect(
        () => LauncherOptions.parse(['build', '--mode=rust', ...arguments]),
        throwsFormatException,
      );
    }
  });
}
