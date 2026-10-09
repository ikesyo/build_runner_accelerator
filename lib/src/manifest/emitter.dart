import 'dart:convert';
import 'dart:io';

import 'model.dart';
import 'source.dart';

const _manifestVersion = 9;

/// Writes just the worker entrypoint. `generate_builder_manifest` emits it
/// early — before the factory probe — so the frontend can overlap the
/// synchronous worker AOT compile with the probe window. The catalog must be
/// a superset of the final manifest's entries: an entry that later drops out
/// (a builder that fails conversion) only wastes the overlapping compile.
Future<void> emitWorkerEntrypoint(
  String workerEntrypoint,
  Iterable<CatalogEntry> catalogEntries,
) async {
  final workerFile = File(workerEntrypoint);
  await workerFile.parent.create(recursive: true);
  await _writeAtomically(workerFile, workerSource(catalogEntries));
}

/// Publishes each artifact atomically, binding the manifest to its worker source.
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
  final source = workerSource(catalogEntries);
  await _writeAtomically(workerFile, source);
  final manifest = <String, dynamic>{
    'version': _manifestVersion,
    'fingerprint': fingerprint,
    'trigger_digest': triggerDigest,
    'worker_entrypoint': workerFile.absolute.path,
    'worker_source_digest': workerSourceDigest(source),
    'builders': builders.toList(),
    'definitions': definitions.toList(),
  };
  await _writeAtomically(manifestFile, jsonEncode(manifest) + '\n');
}

/// FNV-1a over UTF-8, matching Rust's disposable-state `digest_bytes` identity.
String workerSourceDigest(String source) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(source)) {
    hash = (hash ^ byte) * 0x100000001b3;
  }
  return (hash >>> 32).toRadixString(16).padLeft(8, '0') +
      (hash & 0xffffffff).toRadixString(16).padLeft(8, '0');
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
    ..writeln('Future<void> main(List<String> args) => runWorker(')
    ..writeln('  arguments: args,')
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
