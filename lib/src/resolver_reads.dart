import 'dart:collection';
import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:package_config/package_config.dart';

import 'remote_build_step.dart';

/// Caches dependency candidates found while inspecting Dart assets.
///
/// Call [clear] when a build starts or the resolver is reset for a new source
/// phase. Asset contents are stable within those boundaries, while a source
/// output from an earlier phase can change what the resolver sees.
class ResolverDependencyCache {
  final Map<AssetId, List<AssetId>> _dependencies = <AssetId, List<AssetId>>{};

  /// Number of Dart assets scanned since the last [clear].
  int get scannedAssetCount => _dependencies.length;

  List<AssetId>? dependenciesFor(AssetId asset) => _dependencies[asset];

  void remember(AssetId asset, List<AssetId> dependencies) {
    _dependencies[asset] = List<AssetId>.unmodifiable(dependencies);
  }

  void clear() => _dependencies.clear();
}

/// Adds conditional import/export candidates to the resolver dependency set.
///
/// build_runner's library-cycle loader already records the ordinary directive
/// graph. The compact worker graph has no library-cycle node, so we retain the
/// same observed asset set and inspect observed Dart sources for conditional
/// directives, parsing only files that might contain namespace directives.
///
/// This is intentionally a dependency collector, not a second Dart resolver:
/// builders still use build_runner's Analyzer-backed resolver.
Future<void> collectResolverReads(
  RemoteAssetReaderWriter io,
  PackageConfig packageConfig,
  ResolverDependencyCache cache,
) async {
  final pending = Queue<AssetId>();
  pending.addAll(io.observedReads.where((asset) => asset.extension == '.dart'));
  final visited = <AssetId>{};

  while (pending.isNotEmpty) {
    final asset = pending.removeFirst();
    if (!visited.add(asset)) continue;

    var dependencies = cache.dependenciesFor(asset);
    if (dependencies == null) {
      List<int> bytes;
      try {
        bytes = await io.readAsBytes(asset);
      } on AssetNotFoundException {
        // A demanded optional output can appear later in this phase. Do not
        // memoize a missing asset across actions.
        continue;
      }

      final content = utf8.decode(bytes, allowMalformed: true);
      if (_containsNamespaceDirectiveCandidate(content)) {
        final unit = parseString(
          content: content,
          throwIfDiagnostics: false,
        ).unit;
        final discovered = <AssetId>{};
        for (final directive in unit.directives) {
          if (directive is! NamespaceDirective ||
              directive.configurations.isEmpty) {
            continue;
          }
          final uris = <String?>[directive.uri.stringValue];
          uris.addAll(
            directive.configurations.map(
              (configuration) => configuration.uri.stringValue,
            ),
          );

          for (final rawUri in uris) {
            final dependency = _resolveDirectiveUri(
              rawUri,
              asset,
              packageConfig,
            );
            if (dependency != null) discovered.add(dependency);
          }
        }
        dependencies = discovered.toList(growable: false);
      } else {
        dependencies = const <AssetId>[];
      }
      cache.remember(asset, dependencies);
    }

    for (final dependency in dependencies) {
      io.observedReads.add(dependency);
      if (dependency.extension == '.dart' && !visited.contains(dependency)) {
        pending.add(dependency);
      }
    }
  }
}

// This permissive candidate check may match comments and strings, but the AST
// pass below recognizes only real directives. Avoid punctuation-sensitive
// checks here because valid directive URIs can contain semicolons.
final _namespaceDirectiveCandidate = RegExp(r'\b(?:import|export)\b');

bool _containsNamespaceDirectiveCandidate(String content) =>
    _namespaceDirectiveCandidate.hasMatch(content);

AssetId? _resolveDirectiveUri(
  String? rawUri,
  AssetId from,
  PackageConfig packageConfig,
) {
  if (rawUri == null || rawUri.isEmpty) return null;

  final uri = Uri.tryParse(rawUri);
  if (uri == null || uri.isScheme('dart') || uri.isScheme('dart-ext')) {
    return null;
  }

  if (uri.isScheme('file')) {
    return _assetIdForFileUri(uri, packageConfig);
  }

  try {
    return AssetId.resolve(uri, from: uri.hasScheme ? null : from);
  } on Object {
    // Unsupported URI schemes and malformed directives are left to the
    // Analyzer/build_runner diagnostics. They are not guessed here.
    return null;
  }
}

AssetId? _assetIdForFileUri(Uri uri, PackageConfig packageConfig) {
  final target = _pathSegments(uri);
  for (final package in packageConfig.packages) {
    if (package.root.scheme != uri.scheme ||
        package.root.authority != uri.authority) {
      continue;
    }
    final root = _pathSegments(package.root);
    if (target.length < root.length) continue;
    var matches = true;
    for (var index = 0; index < root.length; index++) {
      if (target[index] != root[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      final relative = target.skip(root.length).toList();
      if (relative.isEmpty) return null;
      return AssetId(package.name, relative.join('/'));
    }
  }
  return null;
}

List<String> _pathSegments(Uri uri) =>
    uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
