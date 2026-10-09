import 'dart:convert';

import 'package:build_config/build_config.dart';
import 'package:path/path.dart' as p;

/// The native CLI subset of build_runner 2.16.x. Keep spelling/order in the
/// fallback vector; this value is only used for configuration resolution.
class BuildSettings {
  const BuildSettings({
    this.release = false,
    this.config,
    this.defines = const [],
    this.deletionFlag = false,
  });

  final bool release;
  final String? config;
  final List<String> defines;
  final bool deletionFlag;

  /// Stock constructs an AssetId from the prefixed/suffixed name, then
  /// converts backslashes and normalizes POSIX segments inside the package.
  static String configPath(String key) {
    final path = p.posix.normalize('build.$key.yaml'.replaceAll(r'\', '/'));
    if (p.posix.isAbsolute(path) || path == '..' || path.startsWith('../')) {
      throw FormatException('Config asset must be within the package: $key');
    }
    return path;
  }

  static BuildSettings parse(List<String> arguments) {
    // args accepts an attached value only when the first abbreviation is an
    // option. Once the first is a flag, every remaining abbreviation is a flag.
    final expanded = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (const {'--config', '-c', '--define'}.contains(argument)) {
        expanded.add(argument);
        if (i + 1 < arguments.length) expanded.add(arguments[++i]);
      } else if (argument.startsWith('-c') &&
          argument.length > 2 &&
          !argument.contains('\n') &&
          !argument.contains('\r')) {
        expanded.add('--config=${argument.substring(2)}');
      } else if (RegExp(r'^-[rd]+$').hasMatch(argument)) {
        expanded.addAll(
          argument.substring(1).split('').map((flag) => '-$flag'),
        );
      } else {
        expanded.add(argument);
      }
    }
    arguments = expanded;
    var release = false;
    var deletionFlag = false;
    String? config;
    final defines = <String>[];
    final pairs = <(bool, String, String)>{};
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      switch (argument) {
        case '--release' || '-r':
          release = true;
        case '--no-release':
          release = false;
        case '--force-aot' || '--force-jit':
          break;
        case '--delete-conflicting-outputs' || '-d':
          deletionFlag = true;
        default:
          final separator = argument.indexOf('=');
          final name = separator < 0
              ? argument
              : argument.substring(0, separator);
          if (!const {'--config', '-c', '--define'}.contains(name)) {
            throw FormatException('Unsupported native argument: $argument');
          }
          final String value;
          if (separator >= 0) {
            if (name == '-c' ||
                argument.contains('\n') ||
                argument.contains('\r')) {
              throw FormatException('Unsupported spelling: $argument');
            }
            value = argument.substring(separator + 1);
          } else {
            if (++i >= arguments.length) {
              throw FormatException('$name requires a value');
            }
            value = arguments[i];
          }
          if (name == '--define') {
            if (value.split('=').length < 3) {
              throw FormatException(
                'Expected --define <builder>=<option>=<value>',
              );
            }
            final parts = value.split('=');
            // Leading :keys need the actual root name for alias detection;
            // exact duplicates can already be rejected before native setup.
            final key = normalizeBuilderKeyUsage(parts[0], '');
            if (!pairs.add((
              parts[0].replaceFirst('|', ':').startsWith(':'),
              key,
              parts[1],
            ))) {
              throw FormatException('Duplicate --define for $key=${parts[1]}');
            }
            defines.add(value);
          } else {
            config = value;
          }
      }
    }
    if (config != null) configPath(config);
    return BuildSettings(
      release: release,
      config: config,
      defines: defines,
      deletionFlag: deletionFlag,
    );
  }

  /// Mirrors BuildOptions._parseBuilderConfigOverrides: split on the first
  /// two '=', normalize using build_config, JSON when valid, exact string
  /// otherwise. Duplicate normalized builder/option pairs are errors.
  Map<String, Map<String, dynamic>> overrides(String currentPackage) {
    final result = <String, Map<String, dynamic>>{};
    for (final define in defines) {
      final parts = define.split('=');
      final key = normalizeBuilderKeyUsage(parts[0], currentPackage);
      final option = parts[1];
      final text = parts.skip(2).join('=');
      dynamic value;
      try {
        value = jsonDecode(text);
      } on FormatException {
        value = text;
      }
      final options = result.putIfAbsent(key, () => <String, dynamic>{});
      if (options.containsKey(option)) {
        throw ArgumentError(
          'Got duplicate overrides for the same builder option: '
          '$key=$option. Only one is allowed.',
        );
      }
      options[option] = value;
    }
    return result;
  }
}
