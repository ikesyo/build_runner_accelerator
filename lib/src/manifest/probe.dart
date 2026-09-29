import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'mapping.dart';
import '../cache_directory.dart';
import 'model.dart';
import 'source.dart';

const _factoryProbeTimeout = Duration(seconds: 30);
const _factoryProbeKillGracePeriod = Duration(seconds: 1);
const _probeCacheVersion = 1;

/// Probes selected builder factories for mappings that are only available
/// after the configured factory has been instantiated.
///
/// When [cacheKey] is provided the probe response is persisted under the
/// machine-wide cache directory (`<cache>/probe/<key>.json`) and reused
/// verbatim on a hit. The caller keys it by the workspace's builder-manifest
/// fingerprint. The identity of every mutable package in the probed packages'
/// dependency closure is mixed into the effective key, so editing a path
/// dependency invalidates the entry; the cache is skipped entirely when that
/// identity cannot be established.
Future<Map<String, List<FactoryMapping>>> probeFactoryMappings(
  String root,
  Iterable<FactoryProbeRequest> requests, {
  String? cacheKey,
}) async {
  final probeRequests = requests.toList(growable: false);
  if (probeRequests.isEmpty) return const {};
  final packageConfig = _findPackageConfigPath(root);
  if (packageConfig == null) return const {};

  File? cacheFile;
  if (cacheKey != null) {
    final scopedKey = await _implementationScopedCacheKey(
      root,
      packageConfig,
      cacheKey,
      probeRequests,
    );
    if (scopedKey != null) {
      cacheFile = File(
        p.join(
          acceleratorCacheDirectory(workspaceRoot: root),
          'probe',
          '$scopedKey.json',
        ),
      );
    }
  }
  if (cacheFile != null) {
    final cached = _readProbeCache(cacheFile, probeRequests);
    if (cached != null) return cached;
  }

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
    final responseText = await resultFile.readAsString();
    final decoded = decodeFactoryProbeResponse(responseText, probeRequests);
    // Only persist a response that produced a valid mapping for every
    // probeable request — a response missing entries (a factory threw)
    // must not be replayed as a hit and permanently skip the retry.
    if (_coversAllProbeableRequests(decoded, probeRequests)) {
      _writeProbeCache(cacheFile, responseText);
    }
    return decoded;
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

/// Reads a cached probe response, returning null on a miss. A cached
/// entry is a hit only when it decodes into a valid mapping for every
/// probeable request — a partial response must be reprobed.
Map<String, List<FactoryMapping>>? _readProbeCache(
  File cacheFile,
  List<FactoryProbeRequest> requests,
) {
  try {
    final decoded = jsonDecode(cacheFile.readAsStringSync());
    if (decoded is! Map || decoded['version'] != _probeCacheVersion) {
      return null;
    }
    // Reuse the live response validation path so a stale or malformed entry
    // degrades to a miss instead of trusting cached strings.
    final result = decodeFactoryProbeResult(decoded['response'], requests);
    return _coversAllProbeableRequests(result, requests) ? result : null;
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

/// Whether [decoded] carries a mapping for every request that can be probed
/// at all (the same shape check the probe emitter applies).
bool _coversAllProbeableRequests(
  Map<String, List<FactoryMapping>> decoded,
  List<FactoryProbeRequest> requests,
) {
  final ids = decoded.keys.toSet();
  return requests.every(
    (request) => !isProbeableRequest(request) || ids.contains(request.id),
  );
}

/// Whether the probe emitter can turn [request] into executable source —
/// a `package:` import and identifier-shaped factory names.
bool isProbeableRequest(FactoryProbeRequest request) {
  if (request.definition.isPostProcess) {
    final postProcess = request.definition.postProcess!;
    return postProcess.import.startsWith('package:') &&
        manifestIdentifierPattern.hasMatch(postProcess.builderFactory);
  }
  final normal = request.definition.normal!;
  return normal.import.startsWith('package:') &&
      normal.builderFactories.every(manifestIdentifierPattern.hasMatch);
}

/// Writes [responseText] under [cacheFile] atomically, best-effort.
void _writeProbeCache(File? cacheFile, String responseText) {
  if (cacheFile == null) return;
  try {
    final wrapped = jsonEncode(<String, dynamic>{
      'version': _probeCacheVersion,
      'response': jsonDecode(responseText),
    });
    cacheFile.parent.createSync(recursive: true);
    final temporary = File('${cacheFile.path}.tmp.${pid}');
    temporary.writeAsStringSync(wrapped);
    temporary.renameSync(cacheFile.path);
  } on Object {
    // The probe cache is an optimization; never fail manifest generation.
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
      final builderType = raw['builder_type'];
      mappings.add(
        FactoryMapping(
          factory: raw['factory'] as String,
          buildExtensions: buildExtensions,
          inputExtensions: inputExtensions,
          builderType: builderType is String ? builderType : null,
        ),
      );
    }
    if (valid) probed[request.id] = mappings;
  }
  return probed;
}

/// Derives the effective probe-cache key by mixing [cacheKey] with the Dart
/// SDK version and an identity for every package in the probed packages'
/// transitive dependency closure. A probed factory's observable behavior
/// is set by all the code it can reach, so the identity must cover mutable
/// (path/local) transitive dependencies — not only the directly probed
/// packages. Entries under the pub cache (hosted/git) are addressed by
/// name plus their versioned directory — they are immutable for a given
/// version. Everywhere else the sources under `lib/` are digested, so
/// editing a factory implementation or any code it depends on invalidates
/// the cached mapping. The traversal follows `dev_dependencies` and
/// `dependency_overrides` for the workspace's own packages — pub resolves
/// those for the workspace, unlike in dependency pubspecs. Returns null
/// when any reachable package's identity cannot be established; the caller
/// then skips the cache entirely.
Future<String?> _implementationScopedCacheKey(
  String workspaceRoot,
  String packageConfigPath,
  String cacheKey,
  List<FactoryProbeRequest> requests,
) async {
  final packageNames = <String?>{
    for (final request in requests) _importPackage(request),
  }..remove(null);
  if (packageNames.isEmpty) return cacheKey;

  Map<String, String> packageRoots;
  try {
    final decoded = jsonDecode(await File(packageConfigPath).readAsString());
    if (decoded is! Map || decoded['packages'] is! List) return null;
    packageRoots = {
      for (final entry in decoded['packages'] as List)
        if (entry is Map &&
            entry['name'] is String &&
            entry['rootUri'] is String)
          entry['name'] as String: entry['rootUri'] as String,
    };
  } on Object {
    return null;
  }

  final workspacePackages = await _workspacePackageDirs(workspaceRoot);
  if (workspacePackages == null) return null;
  final canonicalRoot = p.canonicalize(workspaceRoot);
  final configDir = p.dirname(packageConfigPath);
  final pubCache = _pubCacheDirectory();
  final identities = <String>[];
  final visited = <String>{};
  final queue = packageNames.nonNulls.toList();
  while (queue.isNotEmpty) {
    final name = queue.removeLast();
    if (!visited.add(name)) continue;
    final rootUri = packageRoots[name];
    if (rootUri == null) return null;
    final rootDir = _resolveRootUri(rootUri, configDir);
    if (rootDir == null) return null;
    if (pubCache != null && p.isWithin(pubCache, rootDir)) {
      // Hosted and git pub-cache entries carry the version/commit in the
      // directory name, and their contents are immutable for that identity.
      identities.add('$name@${p.basename(rootDir)}');
    } else {
      final digest = await _libSourcesDigest(rootDir);
      if (digest == null) return null;
      identities.add('$name@$digest');
    }
    final dependencies = await _dependencyNames(
      rootDir,
      isWorkspacePackage: workspacePackages.contains(rootDir),
      isWorkspaceRoot: rootDir == canonicalRoot,
    );
    if (dependencies == null) return null;
    queue.addAll(dependencies);
  }
  identities.sort();
  // The probe compiles and runs factories under the resolved Dart SDK, so
  // the recorded runtime types and mappings can change with it.
  final keyMaterial = 'dart-sdk:${Platform.version}\n${identities.join('\n')}';
  return '$cacheKey-${sha256.convert(utf8.encode(keyMaterial))}';
}

/// The workspace's package directories — [root] itself plus every member
/// listed in the root pubspec's `workspace:` section — as canonical paths,
/// matching the spelling `_findPackageConfigPath` and `_resolveRootUri`
/// produce so membership checks compare like for like. Pub resolves
/// `dev_dependencies` only for these packages, so they are the only ones
/// whose dev dependencies can contribute to the closure. Null when the root
/// pubspec cannot be read, since membership is then unknowable.
Future<Set<String>?> _workspacePackageDirs(String root) async {
  try {
    final file = File(p.join(root, 'pubspec.yaml'));
    if (!file.existsSync()) return null;
    final doc = loadYaml(await file.readAsString());
    if (doc is! Map) return null;
    final dirs = <String>{p.canonicalize(root)};
    final workspace = doc['workspace'];
    if (workspace is List) {
      for (final member in workspace) {
        if (member is String) {
          dirs.add(p.canonicalize(p.join(root, member)));
        }
      }
    }
    return dirs;
  } on Object {
    return null;
  }
}

/// Dependency names declared in [packageRoot]'s pubspec — the packages whose
/// code a factory in this package can reach. `dev_dependencies` qualify only
/// for workspace packages ([isWorkspacePackage]): a non-root pubspec's dev
/// dependencies are neither resolved into the package config nor importable
/// from `lib/`. `dependency_overrides` qualify only for the workspace root
/// ([isWorkspaceRoot]) — the only pubspec whose overrides pub honors. Null
/// when the pubspec cannot be read or parsed, since the closure is then
/// unknowable.
Future<Set<String>?> _dependencyNames(
  String packageRoot, {
  required bool isWorkspacePackage,
  required bool isWorkspaceRoot,
}) async {
  try {
    final file = File(p.join(packageRoot, 'pubspec.yaml'));
    if (!file.existsSync()) return null;
    final doc = loadYaml(await file.readAsString());
    if (doc is! Map) return null;
    final names = <String>{};
    for (final section in [
      'dependencies',
      if (isWorkspacePackage) 'dev_dependencies',
      if (isWorkspaceRoot) 'dependency_overrides',
    ]) {
      final dependencies = doc[section];
      if (dependencies is! Map) continue;
      for (final name in dependencies.keys) {
        if (name is String) names.add(name);
      }
    }
    return names;
  } on Object {
    return null;
  }
}

/// The package name a `package:` import URI resolves to, or null for other
/// schemes (non-package imports can never be emitted into the probe).
String? _importPackage(FactoryProbeRequest request) {
  final import = request.definition.isPostProcess
      ? request.definition.postProcess!.import
      : request.definition.normal!.import;
  if (!import.startsWith('package:')) return null;
  final slash = import.indexOf('/', 'package:'.length);
  return slash < 0 ? null : import.substring('package:'.length, slash);
}

/// Resolves a package_config `rootUri` — absolute or relative to the config
/// file — into a filesystem path, or null when the URI cannot be resolved.
String? _resolveRootUri(String rootUri, String configDir) {
  try {
    // p.fromUri already decodes percent escapes (file: URIs through
    // toFilePath, other URIs through Uri.path); decoding again would throw
    // on paths that literally contain '%'.
    final decoded = p.fromUri(rootUri);
    return p.canonicalize(
      p.isAbsolute(decoded) ? decoded : p.join(configDir, decoded),
    );
  } on Object {
    return null;
  }
}

/// Digest of every Dart source under the package's `lib/` — the identity of
/// a mutable (path/local) package for cache purposes.
Future<String?> _libSourcesDigest(String packageRoot) async {
  try {
    final lib = Directory(p.join(packageRoot, 'lib'));
    if (!lib.existsSync()) return null;
    final files = await lib
        .list(recursive: true)
        .where((entity) => entity is File && entity.path.endsWith('.dart'))
        .cast<File>()
        .toList();
    files.sort(
      (a, b) => p
          .relative(a.path, from: lib.path)
          .compareTo(p.relative(b.path, from: lib.path)),
    );
    final buffer = BytesBuilder(copy: false);
    for (final file in files) {
      buffer.add(utf8.encode('${p.relative(file.path, from: lib.path)}\x00'));
      buffer.add(await file.readAsBytes());
      buffer.addByte(0);
    }
    return sha256.convert(buffer.toBytes()).toString();
  } on Object {
    return null;
  }
}

/// The pub cache root, using the same precedence as the Dart tools.
String? _pubCacheDirectory() {
  final override = Platform.environment['PUB_CACHE'];
  if (override != null && override.isNotEmpty) {
    return p.normalize(p.absolute(override));
  }
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    return localAppData == null
        ? null
        : p.normalize(p.join(localAppData, 'Pub', 'Cache'));
  }
  final home = Platform.environment['HOME'];
  return home == null ? null : p.normalize(p.join(home, '.pub-cache'));
}

String _factoryProbeSource(Iterable<FactoryProbeRequest> requests) {
  // These values are later emitted into executable Dart source. Keep the
  // probe boundary as strict as the manifest converter: only package imports
  // and identifier-shaped factory names may cross it. In particular, a raw
  // factory value must never reach the importPrefix.factory expression below.
  final safeRequests = requests
      .where(isProbeableRequest)
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
          ..writeln('      _builderEntry(${dartSourceString(factory)},')
          ..writeln('          $importPrefix.$factory($builderOptions)),');
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
      'Map<String, dynamic> _builderEntry(String factory, Builder builder) => '
      '<String, dynamic>{'
      "'factory': factory,"
      // The instantiated builder's runtime type drives the part-directive
      // pre-filter classification, so capture it next to the mapping.
      "'builder_type': builder.runtimeType.toString(),"
      "'build_extensions': <String, List<String>>{"
      'for (final entry in builder.buildExtensions.entries) '
      'entry.key: entry.value.toList(growable: false),'
      '},'
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
