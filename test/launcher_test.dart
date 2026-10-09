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

  test('removed alias fails in every mode', () {
    for (final mode in ['auto', 'rust', 'dart']) {
      expect(
        () => LauncherOptions.parse(['aot-prewarm', '--mode', mode]),
        throwsFormatException,
      );
    }
  });
  test('background is rejected outside prewarm in every frontend mode', () {
    for (final mode in ['auto', 'rust', 'dart']) {
      for (final command in ['build', 'watch', 'clean']) {
        expect(
          () =>
              LauncherOptions.parse([command, '--mode', mode, '--background']),
          throwsFormatException,
        );
      }
      for (final command in ['prewarm']) {
        final options = LauncherOptions.parse([
          command,
          '--mode',
          mode,
          '--background',
        ]);
        expect(options.rustArguments, contains('--background'));
        expect(options.dartArguments, isNot(contains('--background')));
      }
    }
  });

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
      containsAll(<String>['run', 'build_runner', 'build']),
    );
  });

  test('unsupported CLI selects stock before native resolution', () {
    for (final args in [
      ['clean'],
      ['serve'],
      ['test', '--', '--mode', 'rust'],
      ['build', '--build-filter', 'lib/*.g.dart'],
      ['build', '--unknown'],
      ['build', '--help'],
      ['build', '--version'],
      ['build', '--'],
    ]) {
      final options = LauncherOptions.parse(args);
      expect(options.nativeUnsupported, isTrue, reason: '$args');
      expect(options.dartArguments, ['run', 'build_runner', ...args]);
      expect(
        () => LauncherOptions.parse([
          ...args.takeWhile((a) => a != '--'),
          '--mode=rust',
          ...args.skipWhile((a) => a != '--'),
        ]),
        throwsFormatException,
      );
    }
  });

  test('stock values and separator never consume launcher flags', () {
    final options = LauncherOptions.parse([
      'build',
      '--dart-jit-vm-arg',
      '--force-aot',
      '--define',
      '--mode=rust',
      '--',
      '--jobs',
      '0',
      '--force-jit',
      '--help',
    ]);
    expect(options.mode, 'auto');
    expect(options.forceAot, isFalse);
    expect(options.forceJit, isFalse);
    expect(options.showHelp, isFalse);
    expect(options.dartArguments, [
      'run',
      'build_runner',
      'build',
      '--dart-jit-vm-arg',
      '--force-aot',
      '--define',
      '--mode=rust',
      '--',
      '--jobs',
      '0',
      '--force-jit',
      '--help',
    ]);
  });

  test('stock command order is preserved', () {
    final options = LauncherOptions.parse(['--force-jit', 'build', '-d']);
    expect(options.nativeUnsupported, isTrue);
    expect(options.dartArguments, [
      'run',
      'build_runner',
      '--force-jit',
      'build',
      '-d',
    ]);
  });

  test('native stock flags survive manifest fallback transport', () {
    final options = LauncherOptions.parse(['watch', '-d', '--force-jit']);
    expect(options.nativeUnsupported, isFalse);
    expect(options.dartArguments, [
      'run',
      'build_runner',
      'watch',
      '-d',
      '--force-jit',
    ]);
    expect(
      options.rustArguments.last,
      contains('"arguments":["-d","--force-jit"]'),
    );
    expect(
      options.rustArguments.last,
      contains('"invocation":["watch","-d","--force-jit"]'),
    );
    expect(options.rustArguments, contains('--stock-arguments-json'));
  });

  test('invalid accelerator values fail in every mode', () {
    for (final mode in ['auto', 'dart', 'rust']) {
      for (final args in [
        ['--jobs', '0'],
        ['--jobs=abc'],
        ['--interval-ms=-1'],
        ['--root'],
        ['--dart', '--help'],
        ['--worker='],
      ]) {
        expect(
          () => LauncherOptions.parse(['--mode=$mode', ...args]),
          throwsFormatException,
        );
      }
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
      expect(result.stdout, contains('Usage: dart run'));
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
