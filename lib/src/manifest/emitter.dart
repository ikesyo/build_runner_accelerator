import 'dart:convert';
import 'dart:io';

import 'model.dart';
import 'source.dart';

const _manifestVersion = 8;

/// Emits the normalized manifest and the worker entrypoint atomically.
Future<void> emitManifestArtifacts({
  required String manifestPath,
  required String workerEntrypoint,
  required String fingerprint,
  required Iterable<Map<String, dynamic>> builders,
  required Iterable<Map<String, dynamic>> definitions,
  required Iterable<CatalogEntry> catalogEntries,
  required String triggerDigest,
}) async {
  final manifestFile = File(manifestPath);
  final workerFile = File(workerEntrypoint);
  await manifestFile.parent.create(recursive: true);
  await workerFile.parent.create(recursive: true);
  await _writeAtomically(workerFile, workerSource(catalogEntries));
  final manifest = <String, dynamic>{
    'version': _manifestVersion,
    'fingerprint': fingerprint,
    'trigger_digest': triggerDigest,
    'worker_entrypoint': workerFile.absolute.path,
    'builders': builders.toList(),
    'definitions': definitions.toList(),
  };
  await _writeAtomically(manifestFile, jsonEncode(manifest) + '\n');
}

String workerSource(Iterable<CatalogEntry> entries) {
  final sorted = entries.toList()
    ..sort((left, right) => left.id.compareTo(right.id));
  final imports = <String, String>{};
  for (final entry in sorted) {
    imports.putIfAbsent(
      entry.importUri,
      () => 'builderImport' + imports.length.toString(),
    );
  }

  final output = StringBuffer()
    ..writeln(
      "import 'package:build/build.dart' show BuilderFactory, PostProcessBuilderFactory;",
    )
    ..writeln("import 'package:build_runner_accelerator/src/worker.dart';");
  for (final entry in imports.entries) {
    output.writeln(
      'import ' + dartSourceString(entry.key) + ' as ' + entry.value + ';',
    );
  }
  output
    ..writeln()
    ..writeln('Future<void> main() => runWorker(')
    ..writeln('  catalog: <String, BuilderFactory>{');
  for (final entry in sorted.where((entry) => !entry.isPostProcess)) {
    output.writeln(
      '    ' +
          dartSourceString(entry.id) +
          ': ' +
          imports[entry.importUri]! +
          '.' +
          entry.factory +
          ',',
    );
  }
  output
    ..writeln('  },')
    ..writeln('  postProcessCatalog: <String, PostProcessBuilderFactory>{');
  for (final entry in sorted.where((entry) => entry.isPostProcess)) {
    output.writeln(
      '    ' +
          dartSourceString(entry.id) +
          ': ' +
          imports[entry.importUri]! +
          '.' +
          entry.factory +
          ',',
    );
  }
  output
    ..writeln('  },')
    ..writeln(');');
  return output.toString();
}

Future<void> _writeAtomically(File file, String contents) async {
  final temporary = File(file.path + '.tmp.' + pid.toString());
  await temporary.writeAsString(contents);
  await temporary.rename(file.path);
}
