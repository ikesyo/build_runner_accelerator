import 'dart:convert';

import 'package:build_config/build_config.dart';

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

  static BuildSettings parse(List<String> arguments) {
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
            // Stock's -cVALUE spelling is outside this native subset.
            if (name == '-c')
              throw FormatException('Unsupported spelling: $argument');
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
            // AssetId/path semantics outside a single root filename are
            // deliberately left to stock, including traversal/absolute paths.
            if (value.contains('/') || value.contains('\\')) {
              throw FormatException('Unsupported config name: $value');
            }
            config = value;
          }
      }
    }
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
