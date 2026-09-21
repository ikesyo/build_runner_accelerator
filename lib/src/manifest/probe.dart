import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'mapping.dart';
import 'model.dart';
import 'source.dart';

const _factoryProbeTimeout = Duration(seconds: 30);
const _factoryProbeKillGracePeriod = Duration(seconds: 1);

/// Probes selected builder factories for mappings that are only available
/// after the configured factory has been instantiated.
Future<Map<String, List<FactoryMapping>>> probeFactoryMappings(
  String root,
  Iterable<FactoryProbeRequest> requests,
) async {
  final probeRequests = requests.toList(growable: false);
  if (probeRequests.isEmpty) return const {};
  final packageConfig = _findPackageConfigPath(root);
  if (packageConfig == null) return const {};

  Directory? temporary;
  try {
    temporary = await Directory.systemTemp.createTemp(
      'build-runner-accelerator-factory-probe-',
    );
    final probeFile = File(p.join(temporary.path, 'probe.dart'));
    final resultFile = File(p.join(temporary.path, 'result.json'));
    await probeFile.writeAsString(_factoryProbeSource(probeRequests));
    // Process.start is required here so a misbehaving factory probe can be
    // terminated instead of blocking manifest generation indefinitely.
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=$packageConfig',
      probeFile.path,
      resultFile.path,
    ], workingDirectory: root);
    // Consume both pipes while the probe runs; otherwise a verbose probe can
    // block on a full child-process pipe before the timeout is reached.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final exitCode = await waitForProbeExit(
      exitCode: process.exitCode,
      kill: process.kill,
    );
    if (exitCode != 0 || !resultFile.existsSync()) return const {};
    return decodeFactoryProbeResponse(
      await resultFile.readAsString(),
      probeRequests,
    );
  } catch (_) {
    // A probe is an optimization boundary, not a reason to fail the build.
    // The caller treats a missing selected request as an unsupported manifest
    // and falls back to stock Dart build_runner in auto mode.
    return const {};
  } finally {
    if (temporary != null) {
      try {
        await temporary.delete(recursive: true);
      } catch (_) {
        // Cleanup is best effort; the probe must not fail the build.
      }
    }
  }
}

/// Waits for a probe process without allowing it to block manifest generation
/// indefinitely. A null result means that the process exceeded its timeout.
Future<int?> waitForProbeExit({
  required Future<int> exitCode,
  required void Function() kill,
  Duration timeout = _factoryProbeTimeout,
  Duration killGracePeriod = _factoryProbeKillGracePeriod,
}) async {
  try {
    return await exitCode.timeout(timeout);
  } on TimeoutException {
    kill();
    try {
      await exitCode.timeout(killGracePeriod);
    } on TimeoutException {
      // The child may be outside our control; the probe still must not
      // keep manifest generation blocked.
    }
    return null;
  }
}

/// Decodes a probe result and keeps only entries matching their requests.
/// Invalid JSON is treated like an unavailable probe.
Map<String, List<FactoryMapping>> decodeFactoryProbeResponse(
  String source,
  Iterable<FactoryProbeRequest> requests,
) {
  try {
    return decodeFactoryProbeResult(jsonDecode(source), requests);
  } on FormatException {
    return const {};
  }
}

Map<String, List<FactoryMapping>> decodeFactoryProbeResult(
  Object? decoded,
  Iterable<FactoryProbeRequest> requests,
) {
  if (decoded is! Map) return const {};

  final requestsById = <String, FactoryProbeRequest>{
    for (final request in requests) request.id: request,
  };
  final probed = <String, List<FactoryMapping>>{};
  for (final entry in decoded.entries) {
    final request = requestsById[entry.key];
    if (request == null || entry.value is! List) continue;
    final expectedFactories = request.definition.isPostProcess
        ? <String>[request.definition.postProcess!.builderFactory]
        : request.definition.normal!.builderFactories;
    final rawMappings = entry.value as List;
    if (rawMappings.length != expectedFactories.length) continue;
    final mappings = <FactoryMapping>[];
    var valid = true;
    for (var index = 0; index < rawMappings.length; index++) {
      final raw = rawMappings[index];
      if (raw is! Map || raw['factory'] != expectedFactories[index]) {
        valid = false;
        break;
      }
      final rawBuildExtensions = raw['build_extensions'];
      if (rawBuildExtensions is! Map) {
        valid = false;
        break;
      }
      final buildExtensions = <String, List<String>>{};
      for (final extension in rawBuildExtensions.entries) {
        final input = extension.key;
        final outputs = extension.value;
        if (input is! String ||
            outputs is! List ||
            outputs.any((output) => output is! String)) {
          valid = false;
          break;
        }
        buildExtensions[input] = outputs.cast<String>();
      }
      if (!valid) break;
      final rawInputExtensions = raw['input_extensions'];
      final inputExtensions = rawInputExtensions == null
          ? null
          : rawInputExtensions is List &&
                rawInputExtensions.every((input) => input is String)
          ? rawInputExtensions.cast<String>()
          : null;
      if (raw.containsKey('input_extensions') && inputExtensions == null) {
        valid = false;
        break;
      }
      mappings.add(
        FactoryMapping(
          factory: raw['factory'] as String,
          buildExtensions: buildExtensions,
          inputExtensions: inputExtensions,
        ),
      );
    }
    if (valid) probed[request.id] = mappings;
  }
  return probed;
}

String _factoryProbeSource(Iterable<FactoryProbeRequest> requests) {
  // These values are later emitted into executable Dart source. Keep the
  // probe boundary as strict as the manifest converter: only package imports
  // and identifier-shaped factory names may cross it. In particular, a raw
  // factory value must never reach the importPrefix.factory expression below.
  final safeRequests = requests
      .where((request) {
        if (request.definition.isPostProcess) {
          final postProcess = request.definition.postProcess!;
          return postProcess.import.startsWith('package:') &&
              manifestIdentifierPattern.hasMatch(postProcess.builderFactory);
        }
        final normal = request.definition.normal!;
        return normal.import.startsWith('package:') &&
            normal.builderFactories.every(manifestIdentifierPattern.hasMatch);
      })
      .toList(growable: false);
  final sorted = safeRequests.toList()
    ..sort((left, right) => left.id.compareTo(right.id));
  final imports = <String, String>{};
  for (final request in sorted) {
    final importUri = request.definition.isPostProcess
        ? request.definition.postProcess!.import
        : request.definition.normal!.import;
    imports.putIfAbsent(
      importUri,
      () => 'builderImport' + imports.length.toString(),
    );
  }

  final output = StringBuffer()
    ..writeln('import \'dart:convert\';')
    ..writeln('import \'dart:io\';')
    ..writeln(
      "import 'package:build/build.dart' show Builder, BuilderOptions, PostProcessBuilder;",
    );
  for (final entry in imports.entries) {
    output.writeln(
      'import ' + dartSourceString(entry.key) + ' as ' + entry.value + ';',
    );
  }
  output
    ..writeln()
    ..writeln('void main(List<String> args) {')
    ..writeln('  if (args.length != 1) {')
    ..writeln('    exitCode = 64;')
    ..writeln('    return;')
    ..writeln('  }')
    ..writeln('  final result = <String, dynamic>{};');
  for (final request in sorted) {
    final importUri = request.definition.isPostProcess
        ? request.definition.postProcess!.import
        : request.definition.normal!.import;
    final importPrefix = imports[importUri]!;
    final optionsLiteral = dartSourceString(jsonEncode(request.options));
    final builderOptions =
        'BuilderOptions('
        'Map<String, dynamic>.from(jsonDecode($optionsLiteral) as Map), '
        'isRoot: ${request.isRoot})';
    output
      ..writeln('    try {')
      ..writeln('      result[${dartSourceString(request.id)}] = <dynamic>[');
    if (request.definition.isPostProcess) {
      final factory = request.definition.postProcess!.builderFactory;
      output
        ..writeln('      <String, dynamic>{')
        ..writeln('        \'factory\': ${dartSourceString(factory)},')
        ..writeln("        'build_extensions': <String, List<String>>{},")
        ..writeln(
          '        \'input_extensions\': _postProcessInputExtensions('
          '$importPrefix.$factory($builderOptions)),',
        )
        ..writeln('      },');
    } else {
      for (final factory in request.definition.normal!.builderFactories) {
        output
          ..writeln('      <String, dynamic>{')
          ..writeln('        \'factory\': ${dartSourceString(factory)},')
          ..writeln("        'build_extensions': _builderBuildExtensions(")
          ..writeln('          $importPrefix.$factory($builderOptions),')
          ..writeln('        ),')
          ..writeln('      },');
      }
    }
    output
      ..writeln('      ];')
      ..writeln('    } catch (_) {}');
  }
  output
    ..writeln('  File(args.single).writeAsStringSync(jsonEncode(result));')
    ..writeln('}')
    ..writeln()
    ..writeln(
      'Map<String, List<String>> _builderBuildExtensions(Builder builder) => '
      '<String, List<String>>{'
      'for (final entry in builder.buildExtensions.entries) '
      'entry.key: entry.value.toList(growable: false),'
      '};',
    )
    ..writeln()
    ..writeln(
      'List<String> _postProcessInputExtensions(PostProcessBuilder builder) '
      '=> builder.inputExtensions.toList(growable: false);',
    );
  return output.toString();
}

String? _findPackageConfigPath(String root) {
  var packageConfigRoot = p.canonicalize(root);
  while (true) {
    final candidate = p.join(
      packageConfigRoot,
      '.dart_tool',
      'package_config.json',
    );
    if (File(candidate).existsSync()) return candidate;
    final parent = p.dirname(packageConfigRoot);
    if (parent == packageConfigRoot) return null;
    packageConfigRoot = parent;
  }
}
