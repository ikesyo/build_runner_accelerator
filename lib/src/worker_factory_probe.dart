import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';

/// Runs in a separate worker process, before any build runtime or IPC starts.
/// Factory exceptions leave that request absent, as in the source probe.
void runWorkerFactoryProbe({
  required String requestsPath,
  required String resultPath,
  required Map<String, BuilderFactory> catalog,
  required Map<String, PostProcessBuilderFactory> postProcessCatalog,
}) {
  final requests = jsonDecode(File(requestsPath).readAsStringSync()) as List
    ..sort(
      (left, right) => (left['id'] as String).compareTo(right['id'] as String),
    );
  final result = <String, dynamic>{};
  for (final raw in requests) {
    final request = raw as Map;
    try {
      final entries = <Map<String, dynamic>>[];
      for (final rawFactory in request['factories'] as List) {
        // Source probes decode a fresh options literal for each factory.
        // Preserve that isolation even if a factory mutates nested values.
        final options = BuilderOptions(
          Map<String, dynamic>.from(
            jsonDecode(jsonEncode(request['options'])) as Map,
          ),
          isRoot: request['is_root'] as bool,
        );
        final factory = rawFactory as Map;
        final id = factory['id'] as String;
        final name = factory['name'] as String;
        if (request['post_process'] == true) {
          final builder = postProcessCatalog[id]!(options);
          entries.add(<String, dynamic>{
            'factory': name,
            'build_extensions': <String, List<String>>{},
            'input_extensions': builder.inputExtensions.toList(growable: false),
          });
        } else {
          entries.add(factoryProbeEntry(name, catalog[id]!(options)));
        }
      }
      result[request['id'] as String] = entries;
    } catch (_) {}
  }
  File(resultPath).writeAsStringSync(jsonEncode(result));
}

Map<String, dynamic> factoryProbeEntry(String factory, Builder builder) =>
    <String, dynamic>{
      'factory': factory,
      'builder_type': builder.runtimeType.toString(),
      'build_extensions': <String, List<String>>{
        for (final entry in builder.buildExtensions.entries)
          entry.key: entry.value.toList(growable: false),
      },
    };
