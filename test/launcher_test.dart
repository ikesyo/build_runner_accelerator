import 'dart:io';
import 'dart:isolate';

import 'package:build_runner_accelerator/src/launcher.dart';
import 'package:build_runner_accelerator/src/launcher_options.dart'
    show resolveDartSdkExecutable;
import 'package:test/test.dart';

void main() {
  test('help forms select the overview or a command', () {
    for (final args in [
      <String>['help'],
      ['--help'],
      ['-h'],
    ]) {
      final options = LauncherOptions.parse(args);
      expect(options.showHelp, isTrue);
      expect(options.helpCommand, isNull);
    }
    for (final command in ['build', 'watch', 'prewarm']) {
      for (final args in [
        ['help', command],
        [command, '--help'],
        [command, '-h'],
        ['--help', command],
      ]) {
        final options = LauncherOptions.parse(args);
        expect(options.showHelp, isTrue);
        expect(options.helpCommand, command);
      }
    }
    expect(LauncherOptions.parse([]).command, 'build');
    expect(LauncherOptions.parse([]).showHelp, isFalse);
    for (final args in [
      ['help', 'unknown'],
      ['help', 'aot-cache-key'],
      ['aot-cache-key', '--help'],
      ['--help', 'aot-cache-key'],
      ['help', 'build', 'watch'],
      ['unknown', '--help'],
      ['help', '--', 'build'],
    ]) {
      expect(() => LauncherOptions.parse(args), throwsFormatException);
    }
  });

  test(
    'help works without a project or native binary and leaves no state',
    () async {
      final root = await Directory.systemTemp.createTemp('accelerator-help-');
      addTearDown(() => root.delete(recursive: true));
      final launcher = File('bin/build_runner_accelerator.dart').absolute.path;
      final packages = File('.dart_tool/package_config.json').absolute.path;
      Future<ProcessResult> help(List<String> arguments) => Process.run(
        Platform.resolvedExecutable,
        ['--packages=$packages', launcher, ...arguments],
        workingDirectory: root.path,
        environment: {
          'BUILD_RUNNER_ACCELERATOR_BIN': '${root.path}/missing-native',
        },
      );
      final overview = await help(['help']);
      expect(overview.exitCode, 0, reason: '${overview.stderr}');
      expect(overview.stdout, contains('Available commands:'));
      expect(overview.stdout, isNot(contains('aot-cache-key')));
      expect(overview.stdout, isNot(contains('--build-filter')));
      expect((await help(['--help'])).stdout, overview.stdout);
      for (final command in ['build', 'watch', 'prewarm']) {
        final result = await help(['help', command]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stderr, isEmpty);
        expect(
          result.stdout,
          contains('Usage: build_runner_accelerator $command'),
        );
        expect((await help([command, '--help'])).stdout, result.stdout);
        expect((await help([command, '-h'])).stdout, result.stdout);
        expect(
          result.stdout.toString().contains('--build-filter'),
          command == 'build' || command == 'watch',
        );
        expect(
          result.stdout.toString().contains('--only-check'),
          command == 'build',
        );
        expect(
          result.stdout.toString().contains('--background'),
          command == 'prewarm',
        );
        expect(
          result.stdout.toString().contains('--interval-ms'),
          command == 'watch',
        );
      }
      final invalid = await help(['help', 'unknown']);
      expect(invalid.exitCode, 1);
      expect(invalid.stderr, contains('Usage: help'));
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('launcher compilation excludes YAML configuration parsers', () async {
    final packageLibrary = (await Isolate.resolvePackageUri(
      Uri.parse('package:build_runner_accelerator/'),
    ))!;
    final packageRoot = Directory.fromUri(packageLibrary.resolve('..'));
    final temporary = await Directory.systemTemp.createTemp('launcher-deps-');
    addTearDown(() => temporary.delete(recursive: true));
    final depfile = File('${temporary.path}/launcher.d');
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
      '--depfile=${depfile.path}',
      '-o',
      '${temporary.path}/launcher.dill',
      '${packageRoot.path}/bin/build_runner_accelerator.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final dependencies = (await depfile.readAsString()).replaceAll(r'\', '/');
    expect(dependencies, isNot(contains('/lib/build_config.dart')));
    expect(dependencies, isNot(contains('/lib/yaml.dart')));
    expect(dependencies, contains('/src/key_normalization.dart'));
  });

  test('filtered jobs stay implicit unless explicitly selected', () {
    expect(
      LauncherOptions.parse(['build', '--build-filter=lib/**']).rustArguments,
      isNot(contains('--jobs')),
    );
    expect(
      LauncherOptions.parse([
        'build',
        '--build-filter=lib/**',
        '--jobs=4',
      ]).rustArguments,
      containsAll(['--jobs', '4']),
    );
  });

  test('explicit --dart skips lookup', () async {
    final pathDirectory = await Directory.systemTemp.createTemp(
      'build-runner-accelerator-path-lookup-',
    );
    final lookupMarker = File('${pathDirectory.path}/lookup-called');
    final which = File('${pathDirectory.path}/which');
    final packageConfig = File('.dart_tool/package_config.json').absolute.path;
    final launcher = File('bin/build_runner_accelerator.dart').absolute.path;
    try {
      await which.writeAsString('#!/bin/sh\n: > "\$LOOKUP_MARKER"\nexit 1\n');
      final chmod = await Process.run('/bin/chmod', ['+x', which.path]);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');

      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=$packageConfig',
          launcher,
          '--dart',
          Platform.resolvedExecutable,
          '--help',
        ],
        workingDirectory: Directory.current.path,
        environment: <String, String>{
          ...Platform.environment,
          'PATH': pathDirectory.path,
          'LOOKUP_MARKER': lookupMarker.path,
        },
      );

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        result.stdout,
        contains('Usage: build_runner_accelerator <command>'),
      );
      expect(lookupMarker.existsSync(), isFalse);
    } finally {
      await pathDirectory.delete(recursive: true);
    }
  }, skip: Platform.isWindows);

  test('Dart SDK resolution continues past invalid PATH matches', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'build-runner-accelerator-dart-path-',
    );
    try {
      final invalidSdk = Directory('${temporary.path}/invalid');
      final validSdk = Directory('${temporary.path}/valid');
      await Directory('${invalidSdk.path}/bin').create(recursive: true);
      await File('${invalidSdk.path}/bin/dart').writeAsString('shim');
      await Directory('${validSdk.path}/bin').create(recursive: true);
      await Directory('${validSdk.path}/lib').create();
      final validDart = File('${validSdk.path}/bin/dart');
      await validDart.writeAsString('dart');
      final lookups = <String>[];

      final result = resolveDartSdkExecutable(
        resolvedExecutable: '${temporary.path}/launcher',
        environmentDart: null,
        pathLookup: (executable) {
          lookups.add(executable);
          return executable == 'dart'
              ? <String>['${invalidSdk.path}/bin/dart', validDart.path]
              : const <String>[];
        },
        isWindows: false,
      );

      expect(result, validDart.path);
      expect(lookups, ['dart']);
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  test('valid DART environment binary avoids PATH lookup', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'build-runner-accelerator-dart-env-',
    );
    try {
      final sdk = Directory('${temporary.path}/sdk');
      await Directory('${sdk.path}/bin').create(recursive: true);
      await Directory('${sdk.path}/lib').create();
      final dart = File('${sdk.path}/bin/dart');
      await dart.writeAsString('dart');

      final result = resolveDartSdkExecutable(
        resolvedExecutable: '${temporary.path}/launcher',
        environmentDart: dart.path,
        pathLookup: (executable) =>
            throw StateError('unexpected PATH lookup: $executable'),
        isWindows: false,
      );

      expect(result, dart.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  test(
    'Flutter lookup uses and validates the platform Dart executable',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'build-runner-accelerator-flutter-dart-',
      );
      try {
        final flutter = '${temporary.path}/flutter/bin/flutter';
        final sdkRoot = Directory(
          '${temporary.path}/flutter/bin/cache/dart-sdk',
        );
        final sdkBin = Directory('${sdkRoot.path}/bin');
        await sdkBin.create(recursive: true);
        await Directory('${sdkRoot.path}/lib').create();
        final windowsDart = File('${sdkBin.path}/dart.exe');
        final lookup = (String executable) => switch (executable) {
          'dart' => const <String>[],
          'flutter' => <String>[flutter],
          _ => const <String>[],
        };

        final fallback = resolveDartSdkExecutable(
          resolvedExecutable: '${temporary.path}/launcher',
          environmentDart: null,
          pathLookup: lookup,
          isWindows: true,
        );
        expect(fallback, '${temporary.path}/launcher');

        await windowsDart.writeAsString('dart');
        final result = resolveDartSdkExecutable(
          resolvedExecutable: '${temporary.path}/launcher',
          environmentDart: null,
          pathLookup: lookup,
          isWindows: true,
        );
        expect(result, windowsDart.path);
      } finally {
        await temporary.delete(recursive: true);
      }
    },
  );
}
