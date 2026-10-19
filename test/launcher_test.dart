import 'dart:io';
import 'dart:isolate';

import 'package:build_runner_accelerator/src/launcher.dart';
import 'package:build_runner_accelerator/src/launcher_options.dart'
    show resolveDartSdkExecutable;
import 'package:test/test.dart';

void main() {
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

  test('defaults to native build', () {
    final options = LauncherOptions.parse([]);
    expect(options.command, 'build');
    expect(options.rustArguments.first, 'build');
    expect(options.config, isNull);
  });

  test('removed modes explain migration', () {
    for (final mode in ['auto', 'rust', 'dart', 'native']) {
      for (final args in [
        ['build', '--mode=$mode'],
        ['--mode', mode, 'watch'],
      ]) {
        expect(
          () => LauncherOptions.parse(args),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('--mode was removed in 0.14.0'),
            ),
          ),
        );
      }
    }
  });

  test('unsupported requests fail before native resolution', () {
    for (final args in [
      ['--force-jit', 'build'],
      ['clean'],
      ['serve'],
      ['aot-prewarm'],
      ['build', '--unknown'],
      ['build', '--output', 'out'],
      ['build', '--build-filter=lib/[ab].g.dart'],
      ['build', '--'],
      ['watch', '--only-check'],
      ['prewarm', '--keep-modified-outputs'],
      ['prewarm', '--build-filter=lib/**'],
      ['build', '--background'],
    ]) {
      expect(
        () => LauncherOptions.parse(args),
        throwsFormatException,
        reason: '$args',
      );
    }
    expect(
      LauncherOptions.parse(['prewarm', '--background']).rustArguments,
      contains('--background'),
    );
  });

  test('launcher owns leading and command help/version', () {
    for (final args in [
      ['--help'],
      ['build', '--help'],
      ['watch', '-h'],
    ]) {
      expect(LauncherOptions.parse(args).showHelp, isTrue);
    }
    expect(LauncherOptions.parse(['build', '--version']).showVersion, isTrue);
  });

  test('native settings retain argument boundaries', () {
    final flags = [
      '--config',
      '--mode=rust',
      '--define=:b=text=a=b,c',
      '--build-filter=lib/*.final',
      '--force-jit',
    ];
    final options = LauncherOptions.parse(['build', '--jobs=2', ...flags]);
    expect(options.config, '--mode=rust');
    expect(
      options.rustArguments.skip(options.rustArguments.length - flags.length),
      flags,
    );
    expect(options.rustArguments, containsAll(['--jobs', '2']));
    final value = LauncherOptions.parse(['build', '--config', '--help']);
    expect(value.showHelp, isFalse);
    expect(value.config, '--help');
    expect(value.rustArguments, containsAllInOrder(['--config', '--help']));
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

  test('invalid launcher values and conflicting compile flags fail', () {
    for (final args in [
      ['--jobs', '0'],
      ['--jobs=abc'],
      ['--interval-ms=-1'],
      ['--root'],
      ['--dart', '--help'],
      ['--worker='],
      ['build', '--force-aot', '--force-jit'],
    ]) {
      expect(() => LauncherOptions.parse(args), throwsFormatException);
    }
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
        contains(
          'build_runner_accelerator <build|watch|prewarm|aot-cache-key>',
        ),
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
