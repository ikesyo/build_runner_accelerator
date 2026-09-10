import 'dart:collection';
import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:package_config/package_config.dart';

import 'remote_build_step.dart';

/// Adds conditional import/export candidates to the resolver dependency set.
///
/// build_runner's library-cycle loader already records the ordinary directive
/// graph. The compact worker graph has no library-cycle node, so we retain the
/// same observed asset set and inspect observed Dart sources for conditional
/// directives, parsing only files that can contribute extra candidates.
///
/// This is intentionally a dependency collector, not a second Dart resolver:
/// builders still use build_runner's Analyzer-backed resolver.
Future<void> collectResolverReads(
  RemoteAssetReaderWriter io,
  PackageConfig packageConfig,
) async {
  final pending = Queue<AssetId>();
  pending.addAll(io.observedReads.where((asset) => asset.extension == '.dart'));
  final visited = <AssetId>{};

  while (pending.isNotEmpty) {
    final asset = pending.removeFirst();
    if (!visited.add(asset)) continue;

    List<int> bytes;
    try {
      bytes = await io.readAsBytes(asset);
    } on AssetNotFoundException {
      continue;
    }

    final content = utf8.decode(bytes, allowMalformed: true);
    if (!_containsConditionalDirective(content)) continue;

    final unit = parseString(content: content, throwIfDiagnostics: false).unit;
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
        final dependency = _resolveDirectiveUri(rawUri, asset, packageConfig);
        if (dependency == null) continue;
        io.observedReads.add(dependency);
        if (dependency.extension == '.dart' && !visited.contains(dependency)) {
          pending.add(dependency);
        }
      }
    }
  }
}

final _conditionalDirective = RegExp(
  r'^\s*(?:import|export)\b[^;]*\bif\s*\(',
  multiLine: true,
);

bool _containsConditionalDirective(String content) =>
    _conditionalDirective.hasMatch(content);

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
