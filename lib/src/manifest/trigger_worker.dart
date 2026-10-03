// Kept outside the manifest generator: the official trigger parser imports
// Analyzer. The generated AOT worker already contains that dependency.
import 'dart:convert';
import 'dart:io';

import 'package:build_config/build_config.dart';
import 'package:build_runner/src/build_plan/build_triggers.dart';
import 'package:built_collection/built_collection.dart';

import 'model.dart';
import 'package_graph.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('usage: trigger_worker <root> <result>');
    exitCode = 64;
    return;
  }
  await writeManifestTriggers(arguments[0], arguments[1]);
}

Future<void> writeManifestTriggers(String root, String resultPath) async {
  Map<String, Object> response;
  try {
    final configs = await loadBuildConfigs(await loadPackageGraph(root));
    response = manifestTriggerData(configs);
  } on StateError catch (error) {
    if (!error.message.startsWith('Unsupported build trigger')) rethrow;
    response = {
      'error': {
        'kind': 'unsupported-trigger-configuration',
        'message': error.message,
      },
    };
    // The caller decodes this error and reports it once.
    exitCode = 1;
  }
  await File(resultPath).writeAsString(jsonEncode(response));
}

Map<String, Object> manifestTriggerData(Map<String, BuildConfig> configs) {
  final triggers = BuildTriggers.fromConfigs(
    BuiltMap<String, BuildConfig>.from(configs),
  );
  if (triggers.warningsByPackage.isNotEmpty) {
    throw StateError(
      'Unsupported build trigger configuration:\n${triggers.renderWarnings}',
    );
  }
  return {
    'digest': triggers.digest.toString(),
    'triggers': {
      for (final entry in normalizedTriggers(triggers).entries)
        entry.key: [for (final trigger in entry.value) trigger.toJson()],
    },
  };
}

Map<String, List<ManifestTrigger>> normalizedTriggers(
  BuildTriggers buildTriggers,
) {
  final result = <String, List<ManifestTrigger>>{};
  for (final entry in buildTriggers.triggers.entries) {
    final triggers = <ManifestTrigger>[];
    for (final trigger in entry.value) {
      if (trigger is ImportBuildTrigger) {
        triggers.add(ManifestTrigger(kind: 'import', value: trigger.import));
      } else if (trigger is AnnotationBuildTrigger) {
        triggers.add(
          ManifestTrigger(kind: 'annotation', value: trigger.annotation),
        );
      } else {
        throw StateError(
          'Unsupported build trigger type for ${entry.key}: '
          '${trigger.runtimeType}',
        );
      }
    }
    triggers.sort((left, right) {
      final kind = left.kind.compareTo(right.kind);
      return kind != 0 ? kind : left.value.compareTo(right.value);
    });
    result[entry.key] = triggers;
  }
  return result;
}
