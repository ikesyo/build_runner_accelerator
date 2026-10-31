import 'dart:io';

import 'manifest/settings.dart';

/// The small set of launcher options that must be consumed before invoking
/// the native frontend.
class LauncherOptions {
  LauncherOptions._({
    required this.command,
    required this.root,
    required this.dartBinary,
    required this.rustArguments,
    required this.config,
    required this.showHelp,
    required this.showVersion,
    required this.helpCommand,
  });

  factory LauncherOptions.parse(List<String> arguments) {
    var command = 'build';
    var commandSeen = false;
    var root = Directory.current.absolute.path;
    var dartBinary = Platform.resolvedExecutable;
    var dartBinaryExplicit = false;
    var forceAot = false;
    var forceJit = false;
    var showHelp = false;
    var showVersion = false;
    var separated = false;
    final rustArguments = <String>[];
    final passthrough = <String>[];

    String takeValue(List<String> values, String option, int index) {
      if (index + 1 >= values.length ||
          values[index + 1].isEmpty ||
          values[index + 1].startsWith('-')) {
        throw FormatException('$option requires a value');
      }
      return values[index + 1];
    }

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (separated) {
        passthrough.add(argument);
        continue;
      }
      if (argument == '--') {
        separated = true;
        passthrough.add(argument);
        continue;
      }
      if (argument == '--help' || argument == '-h') {
        showHelp = true;
        continue;
      }
      if (argument == '--version') {
        showVersion = true;
        continue;
      }
      if (argument == '--mode' || argument.startsWith('--mode=')) {
        throw const FormatException(
          '--mode was removed in 0.14.0; remove it to use native execution, '
          'or run dart run build_runner directly',
        );
      }
      if (argument == '--root' || argument.startsWith('--root=')) {
        final value = argument.startsWith('--root=')
            ? argument.substring('--root='.length)
            : takeValue(arguments, '--root', index);
        if (!argument.startsWith('--root=')) index++;
        if (value.isEmpty) throw FormatException('--root requires a value');
        root = Directory(value).absolute.path;
        continue;
      }
      if (argument == '--dart' || argument.startsWith('--dart=')) {
        final value = argument.startsWith('--dart=')
            ? argument.substring('--dart='.length)
            : takeValue(arguments, '--dart', index);
        if (!argument.startsWith('--dart=')) index++;
        if (value.isEmpty) throw FormatException('--dart requires a value');
        dartBinary = value;
        dartBinaryExplicit = true;
        continue;
      }
      if (argument == '--force-aot') {
        forceAot = true;
        passthrough.add(argument);
        continue;
      }
      if (argument == '--force-jit') {
        forceJit = true;
        passthrough.add(argument);
        continue;
      }

      if (!commandSeen && !argument.startsWith('-')) {
        if (passthrough.isNotEmpty) {
          throw const FormatException(
            'Build arguments must follow the command',
          );
        }
        command = argument;
        commandSeen = true;
        continue;
      }

      // Launcher controls are separate from builder settings.
      const rustFlagOptions = {'--background'};
      const rustValueOptions = {'--jobs', '--interval-ms', '--worker'};
      if (rustFlagOptions.contains(argument)) {
        rustArguments.add(argument);
      } else if (rustValueOptions.contains(argument)) {
        final value = takeValue(arguments, argument, index);
        index++;
        if ((argument == '--jobs' || argument == '--interval-ms') &&
            (int.tryParse(value) == null || int.parse(value) <= 0)) {
          throw FormatException('$argument must be a positive integer');
        }
        rustArguments.addAll([argument, value]);
      } else if (argument.startsWith('--jobs=') ||
          argument.startsWith('--interval-ms=') ||
          argument.startsWith('--worker=')) {
        final separator = argument.indexOf('=');
        final option = argument.substring(0, separator);
        final value = argument.substring(separator + 1);
        if (value.isEmpty) throw FormatException('$option requires a value');
        if ((option == '--jobs' || option == '--interval-ms') &&
            (int.tryParse(value) == null || int.parse(value) <= 0)) {
          throw FormatException('$option must be a positive integer');
        }
        rustArguments.addAll([option, value]);
      } else {
        passthrough.add(argument);
        // Configuration values may look like launcher flags.
        const buildValueOptions = {
          '--build-filter',
          '--enable-experiment',
          '--config',
          '-c',
          '--define',
        };
        if (buildValueOptions.contains(argument) &&
            index + 1 < arguments.length) {
          passthrough.add(arguments[++index]);
        }
      }
    }

    String? helpCommand;
    const commands = {'build', 'watch', 'prewarm'};
    if (command == 'help') {
      showHelp = true;
      if (passthrough.length > 1 ||
          (passthrough.isNotEmpty && !commands.contains(passthrough.single))) {
        throw const FormatException('Usage: help [build|watch|prewarm]');
      }
      helpCommand = passthrough.isEmpty ? null : passthrough.single;
    } else if (showHelp && commandSeen) {
      if (!commands.contains(command)) {
        throw FormatException('Unsupported command: $command');
      }
      helpCommand = command;
    }

    if (rustArguments.contains('--background') && command != 'prewarm') {
      throw FormatException('--background is only supported with prewarm');
    }

    if (command == 'aot-prewarm') {
      throw const FormatException('aot-prewarm was removed; use prewarm');
    }

    if (!dartBinaryExplicit) dartBinary = _defaultDartBinary();

    if (forceAot && forceJit) {
      throw FormatException(
        'Only one compile mode can be used, got --force-aot and --force-jit.',
      );
    }

    rustArguments.insert(0, command);
    rustArguments.addAll(['--root', root, '--dart', dartBinary]);
    String? config;
    if (!showHelp && !showVersion) {
      if (!commands.contains(command)) {
        throw FormatException(
          'Unsupported command: $command; run dart run build_runner directly if needed',
        );
      }
      final settings = BuildSettings.parse(passthrough);
      config = settings.config;
      if (settings.workspace &&
          (command != 'build' ||
              settings.onlyCheck ||
              settings.keepModifiedOutputs ||
              settings.buildFilters.isNotEmpty ||
              settings.config != null ||
              settings.defines.isNotEmpty)) {
        throw FormatException(
          '--workspace currently supports build without filters, output policies, '
          'named configs or --define',
        );
      }
      if (command != 'build' &&
          (settings.onlyCheck || settings.keepModifiedOutputs)) {
        throw FormatException('Output policies are supported only with build');
      }
      if (!const {'build', 'watch'}.contains(command) &&
          (settings.deletionFlag || settings.buildFilters.isNotEmpty)) {
        throw FormatException('$command does not accept build-only arguments');
      }
    }
    rustArguments.addAll(passthrough);

    return LauncherOptions._(
      command: command,
      root: root,
      dartBinary: dartBinary,
      rustArguments: List.unmodifiable(rustArguments),
      config: config,
      showHelp: showHelp,
      showVersion: showVersion,
      helpCommand: helpCommand,
    );
  }

  final String command;
  final String root;
  final String dartBinary;
  final List<String> rustArguments;
  final String? config;
  final bool showHelp;
  final bool showVersion;
  final String? helpCommand;
}

/// The Dart SDK executable to default to.
///
/// `Platform.resolvedExecutable` is the running `dart` only while the
/// launcher runs under the VM; an AOT-compiled launcher resolves to itself.
/// Only accept a path that looks like a real Dart SDK binary
/// (`<sdk>/bin/dart` beside `<sdk>/lib`), then try `DART`/`FLUTTER` and
/// `PATH` lookups before giving up.
String _defaultDartBinary() {
  return resolveDartSdkExecutable(
    resolvedExecutable: Platform.resolvedExecutable,
    environmentDart: Platform.environment['DART'],
    pathLookup: _which,
    isWindows: Platform.isWindows,
  );
}

/// Resolves a usable Dart SDK executable from the running process, `DART`,
/// `PATH`, and a Flutter SDK found on `PATH`, in that order.
String resolveDartSdkExecutable({
  required String resolvedExecutable,
  required String? environmentDart,
  required List<String> Function(String executable) pathLookup,
  required bool isWindows,
}) {
  final resolved = resolvedExecutable;
  if (_isDartSdkExecutable(resolved)) return resolved;

  if (environmentDart != null && _isDartSdkExecutable(environmentDart)) {
    return environmentDart;
  }

  for (final onPath in pathLookup('dart')) {
    if (_isDartSdkExecutable(onPath)) return onPath;
  }

  for (final flutter in pathLookup('flutter')) {
    final candidate = <String>[
      FileSystemEntity.parentOf(flutter),
      'cache',
      'dart-sdk',
      'bin',
      isWindows ? 'dart.exe' : 'dart',
    ].join(Platform.pathSeparator);
    if (_isDartSdkExecutable(candidate)) return candidate;
  }
  return resolved;
}

bool _isDartSdkExecutable(String path) {
  final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  if (name != 'dart' && name != 'dart.exe') return false;
  return File(path).existsSync() &&
      Directory('${FileSystemEntity.parentOf(path)}/../lib').existsSync();
}

List<String> _which(String executable) {
  late final ProcessResult result;
  try {
    result = Process.runSync(Platform.isWindows ? 'where' : 'which', [
      executable,
    ]);
  } on ProcessException {
    return const [];
  }
  if (result.exitCode != 0) return const [];
  return (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}
