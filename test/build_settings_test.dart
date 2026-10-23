import 'package:build/build.dart';
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
      ['-cnamed', '-rrd', '--no-release', '-dr', '-cother'],
      ['-crd'],
      ['-c--force-aot', '--force-jit'],
      ['-c=named'], // '=' is part of the attached value, unlike --config=.
      ['-c/path/to/name'],
      ['--config=dir/name'],
      [r'--config=dir\name'],
      ['--config=dir/../named'],
      ['--config=../named'], // The 'build.' prefix makes '..' a normal segment.
      ['--config=x/../../invalid', '-cnamed'], // Only the last value resolves.
      ['--config', '-rd'], // A value must not be expanded into flags.

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
      expect(
        native.deletionFlag,
        cli.removedOptionsUsed.contains(deleteFilesByDefaultOption),
      );
      if (stock.configKey != null) {
        expect(
          BuildSettings.configPath(native.config!),
          AssetId('example', 'build.${stock.configKey}.yaml').path,
        );
      }
      expect(native.overrides('example'), {
        for (final entry in stock.builderConfigOverrides.entries)
          entry.key: entry.value.asMap(),
      });
    }
  });

  test('output policy syntax agrees with stock', () async {
    final baseline = (await BuildRunnerCommandLine.parse(['build']))!;
    try {
      (baseline as dynamic).outputStrategy;
    } on NoSuchMethodError {
      markTestSkipped(
        'Stock before 2.16 does not expose explicit output policies',
      );
      return;
    }
    for (final flags in <List<String>>[
      [],
      ['--only-check'],
      ['--only-check', '--only-check'],
      ['--keep-modified-outputs'],
      ['--keep-modified-outputs', '-rd'],
      ['--only-check', '--build-filter=lib/*.final', '--force-jit'],
    ]) {
      final settings = BuildSettings.parse(flags);
      final cli = (await BuildRunnerCommandLine.parse(['build', ...flags]))!;
      expect(
        settings.onlyCheck,
        ((cli as dynamic).outputStrategy as Enum).name == 'verify',
      );
      expect(
        settings.keepModifiedOutputs,
        ((cli as dynamic).outputStrategy as Enum).name == 'keep',
      );
      expect(
        LauncherOptions.parse(['build', ...flags]).rustArguments.skip(5),
        flags,
      );
    }
    for (final flags in <List<String>>[
      ['--only-check', '--keep-modified-outputs'],
      ['--no-only-check'],
      ['--no-keep-modified-outputs'],
      ['--only-check=true'],
      ['--keep-modified-outputs=false'],
    ]) {
      expect(() => BuildSettings.parse(flags), throwsFormatException);
      await expectLater(() async {
        final cli = (await BuildRunnerCommandLine.parse(['build', ...flags]))!;
        (cli as dynamic).outputStrategy;
      }, throwsA(anything));
      expect(
        () => LauncherOptions.parse(['build', ...flags]),
        throwsFormatException,
      );
    }
    expect(
      () => LauncherOptions.parse(['build', '--only-check', 'false']),
      throwsFormatException,
    );
    for (final command in ['watch', 'prewarm', 'aot-cache-key']) {
      for (final policy in ['--only-check', '--keep-modified-outputs']) {
        expect(
          () => LauncherOptions.parse([command, policy]),
          throwsFormatException,
        );
      }
    }
  });

  test('build-filter multi-option parsing agrees with stock', () async {
    for (final flags in <List<String>>[
      ['--build-filter=lib/a.final'],
      ['--build-filter', 'lib/a.final,lib/b.final'],
      ['--build-filter=lib/a.final', '--build-filter=asset:*/lib/**'],
      ['--build-filter=package:example*/a.final', '--release', '-cnamed'],
    ]) {
      final native = BuildSettings.parse(flags);
      final cli = (await BuildRunnerCommandLine.parse(['build', ...flags]))!;
      expect(native.buildFilters, cli.buildFilter!.toList());
      final stock = BuildOptions.parse(
        cli,
        buildPaths: BuildPaths(packagePath: '.', buildWorkspace: false),
        currentPackage: 'example',
        restIsBuildDirs: true,
      );
      final matches = stock.buildFilters.any(
        (f) => f.matches(AssetId('example', 'lib/a.final')),
      );
      expect(matches, isTrue);
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

  test('launcher forwards native settings without reconstructing them', () {
    for (final command in ['build', 'watch', 'prewarm', 'aot-cache-key']) {
      final flags = ['-cdir/named', '-rr', '--define=:b=x=a=b,c'];
      expect(
        LauncherOptions.parse([command, ...flags]).rustArguments.skip(5),
        flags,
      );
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
      expect(options.config, '--force-aot');
      expect(options.rustArguments.skip(5), [
        '--config',
        '--force-aot',
        '--force-jit',
      ]);
      expect(BuildSettings.parse(['--config', '-d']).deletionFlag, isFalse);
      expect(LauncherOptions.parse([command, '--config', '-rd']).config, '-rd');
      if (command == 'prewarm') {
        expect(
          () => LauncherOptions.parse([command, '-rd']),
          throwsFormatException,
        );
      }
    }
  });

  test('invalid settings fail before native execution', () {
    for (final arguments in <List<String>>[
      ['--define'],
      ['--define=x=y'],
      ['--define=:b=x=1', '--define=:b=x=2'],
      ['--release=true'],
      ['--no-release=false'],
      ['--config'],
      ['--config=x/../../other'],
      ['-rcnamed'],
      ['-rd=1'],
      ['-cx\nname'],
      ['-c=named\n'],
      ['--config=named\n'],
    ]) {
      expect(
        () => LauncherOptions.parse(['build', ...arguments]),
        throwsFormatException,
      );
    }
  });
}
