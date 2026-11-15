import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

import 'asset_read_cache.dart';
import 'blake3.dart';
import 'cache_directory.dart';
import 'indexed_blob_store.dart';
import 'remote_build_step.dart';
import 'resolver_metrics.dart';
import 'resolver_directives.dart';

/// Caches dependency candidates found while inspecting Dart assets.
///
/// Call [clear] when a build starts or the resolver is reset for a new source
/// phase. Resolved entries are also tied to the asset's content digest because
/// a post-process builder can rewrite its primary input within a phase.
/// Conditional URI extraction survives resets in an SDK-namespaced,
/// content-keyed store; missing/corrupt entries are recomputed. Resolved asset
/// lists are cleared when the package configuration changes. No existence or
/// branch selection result is persisted.
///
/// This cache does not cache action visibility. Callers must read each asset
/// through the active [RemoteAssetReaderWriter] action before using a cached
/// dependency list.
class ResolverDependencyCache {
  ResolverDependencyCache({IndexedBlobStore? directiveStore})
    : _directiveStore = directiveStore ?? _sharedDirectiveStore();

  final IndexedBlobStore? _directiveStore;
  PackageConfig? _packageConfig;

  // Store unresolved URI strings, not AssetIds: file URI mapping depends on
  // package_config, and relative URI mapping depends on the importing asset.
  // Content and SDK grammar identity are sufficient for the extraction itself.
  static IndexedBlobStore? _sharedDirectiveStore() {
    if (Platform.environment['BUILD_RUNNER_ACCELERATOR_DEP_CACHE'] == '0') {
      return null;
    }
    return IndexedBlobStore(
      p.join(
        acceleratorCacheDirectory(),
        'dep_parse',
        'conditional-v2-${Platform.version.split(' ').first}',
        'store.bin',
      ),
    );
  }

  void _bindPackageConfig(PackageConfig packageConfig) {
    if (!identical(_packageConfig, packageConfig)) {
      clear();
      _packageConfig = packageConfig;
    }
  }

  /// The stored conditional URI list for a content [digest], or null when
  /// the persistent store has no valid entry for it. Does not count as a
  /// persistent hit or miss; callers that resolve through it do.
  List<String>? _storedConditionalUris(String digest) {
    final metrics = resolverActionMetrics;
    final lookupTimer = metrics.enabled ? (Stopwatch()..start()) : null;
    final cached = _directiveStore?.get(digest);
    List<String>? uris;
    if (cached != null) {
      try {
        uris = (jsonDecode(utf8.decode(cached)) as List).cast<String>();
        // Force validation now, so malformed cache values become misses.
        uris = List<String>.of(uris);
      } on Object {
        uris = null;
      }
    }
    if (lookupTimer != null) {
      metrics.resolverReadsCacheUs += lookupTimer.elapsedMicroseconds;
    }
    return uris;
  }

  List<String> _conditionalUris(String digest, List<int> bytes) {
    final metrics = resolverActionMetrics;
    final stored = _storedConditionalUris(digest);
    if (stored != null) {
      metrics.resolverReadsPersistentHits++;
      return stored;
    }
    metrics.resolverReadsPersistentMisses++;
    final decodeTimer = metrics.enabled ? (Stopwatch()..start()) : null;
    final content = utf8.decode(bytes, allowMalformed: true);
    final candidate =
        _containsNamespaceDirectiveCandidate(content) &&
        _conditionalDirectiveCandidate.hasMatch(content);
    if (decodeTimer != null) {
      metrics.resolverReadsDecodeUs += decodeTimer.elapsedMicroseconds;
    }
    final uris = <String>[];
    if (candidate) {
      final parseTimer = metrics.enabled ? (Stopwatch()..start()) : null;
      for (final directive in parseResolverDirectives(content)) {
        if (directive is! NamespaceDirective ||
            directive.configurations.isEmpty) {
          continue;
        }
        final base = directive.uri.stringValue;
        if (base != null) uris.add(base);
        for (final configuration in directive.configurations) {
          final uri = configuration.uri.stringValue;
          if (uri != null) uris.add(uri);
        }
      }
      metrics.resolverReadsParses++;
      if (parseTimer != null) {
        metrics.resolverReadsParseUs += parseTimer.elapsedMicroseconds;
      }
    }
    final storeTimer = metrics.enabled ? (Stopwatch()..start()) : null;
    _directiveStore?.put(digest, utf8.encode(jsonEncode(uris)));
    if (storeTimer != null) {
      metrics.resolverReadsCacheUs += storeTimer.elapsedMicroseconds;
    }
    return uris;
  }

  final Map<AssetId, _CachedResolverDependencies> _dependencies =
      <AssetId, _CachedResolverDependencies>{};

  /// Number of Dart assets scanned since the last [clear].
  int get scannedAssetCount => _dependencies.length;

  List<AssetId>? dependenciesFor(AssetId asset, List<int> bytes) {
    return _dependenciesForDigest(asset, _contentDigest(bytes));
  }

  List<AssetId>? _dependenciesForDigest(AssetId asset, String digest) {
    final cached = _dependencies[asset];
    if (cached == null || cached.contentDigest != digest) {
      return null;
    }
    return cached.dependencies;
  }

  void remember(AssetId asset, List<int> bytes, List<AssetId> dependencies) {
    _rememberDigest(asset, _contentDigest(bytes), dependencies);
  }

  void _rememberDigest(
    AssetId asset,
    String digest,
    List<AssetId> dependencies,
  ) {
    _dependencies[asset] = _CachedResolverDependencies(
      digest,
      List<AssetId>.unmodifiable(dependencies),
    );
  }

  void clear() => _dependencies.clear();
}

class _CachedResolverDependencies {
  const _CachedResolverDependencies(this.contentDigest, this.dependencies);

  final String contentDigest;
  final List<AssetId> dependencies;
}

String _contentDigest(List<int> bytes) => blake3Hex(bytes);

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
  ResolverDependencyCache cache, {
  Set<AssetId> excludeReads = const <AssetId>{},
  String? Function(AssetId asset)? frontendDigestFor,
}) async {
  cache._bindPackageConfig(packageConfig);
  final metrics = resolverActionMetrics;
  final pending = Queue<AssetId>();
  pending.addAll(
    io.observedReads.where(
      (asset) => asset.extension == '.dart' && !excludeReads.contains(asset),
    ),
  );
  final visited = <AssetId>{};

  List<AssetId> resolveUris(List<String> uris, AssetId from) {
    final resolveTimer = metrics.enabled ? (Stopwatch()..start()) : null;
    final discovered = <AssetId>{};
    for (final rawUri in uris) {
      final dependency = _resolveDirectiveUri(rawUri, from, packageConfig);
      if (dependency != null) discovered.add(dependency);
    }
    if (resolveTimer != null) {
      metrics.resolverReadsResolveUs += resolveTimer.elapsedMicroseconds;
    }
    return discovered.toList(growable: false);
  }

  void expand(List<AssetId> dependencies) {
    for (final dependency in dependencies) {
      io.observedReads.add(dependency);
      if (dependency.extension == '.dart' && !visited.contains(dependency)) {
        pending.add(dependency);
      }
    }
  }

  while (pending.isNotEmpty) {
    final asset = pending.removeFirst();
    if (!visited.add(asset)) continue;

    // With a frontend-supplied digest (`asset-digests-v1`, ADR 0054) the
    // caches can answer before the asset is read: the store is keyed by
    // content digest, so a hit describes exactly the snapshot content the
    // frontend hashed. The asset is already in this action's observed
    // reads or was recorded when it was discovered, so skipping the read
    // records the same dependency set. On any miss the read path below
    // runs and stores under the worker-computed digest.
    final frontendDigest = frontendDigestFor?.call(asset);
    if (frontendDigest != null) {
      var dependencies = cache._dependenciesForDigest(asset, frontendDigest);
      if (dependencies != null) {
        metrics.resolverReadsMemoryHits++;
        metrics.resolverReadsDigestReuses++;
        expand(dependencies);
        continue;
      }
      final uris = cache._storedConditionalUris(frontendDigest);
      if (uris != null) {
        metrics.resolverReadsPersistentHits++;
        metrics.resolverReadsDigestReuses++;
        dependencies = resolveUris(uris, asset);
        cache._rememberDigest(asset, frontendDigest, dependencies);
        expand(dependencies);
        continue;
      }
    }

    AssetReadContent content;
    final readTimer = metrics.enabled ? (Stopwatch()..start()) : null;
    try {
      // Validate the asset under this action's visibility before consulting
      // cached parse results. The reader also records this action's observed
      // read, and its shared byte cache avoids another RPC when available.
      content = await io.readContent(asset);
    } on AssetNotFoundException {
      // A demanded optional output can appear later in this phase. Do not
      // memoize a missing asset across actions.
      continue;
    } finally {
      if (readTimer != null) {
        metrics.resolverReadsReadUs += readTimer.elapsedMicroseconds;
      }
    }

    final bytes = content.bytes;
    final digestTimer = metrics.enabled ? (Stopwatch()..start()) : null;
    if (content.cachedContentDigest == null) {
      metrics.resolverReadsDigestComputations++;
    } else {
      metrics.resolverReadsDigestReuses++;
    }
    final digest = content.contentDigest;
    if (digestTimer != null) {
      metrics.resolverReadsDigestUs += digestTimer.elapsedMicroseconds;
    }
    var dependencies = cache._dependenciesForDigest(asset, digest);
    if (dependencies == null) {
      final uris = cache._conditionalUris(digest, bytes);
      dependencies = resolveUris(uris, asset);
      cache._rememberDigest(asset, digest, dependencies);
    } else {
      metrics.resolverReadsMemoryHits++;
    }

    expand(dependencies);
  }
}

// This permissive candidate check may match comments and strings, but the AST
// pass below recognizes only real directives. Avoid punctuation-sensitive
// checks here because valid directive URIs can contain semicolons.
final _namespaceDirectiveCandidate = RegExp(r'\b(?:import|export)\b');

// Every conditional configuration needs the literal `if` keyword. Checking
// only the word keeps comments between `if` and `(` and unusual URI strings
// valid; comments/strings/body conditionals can merely cause extra parsing.
final _conditionalDirectiveCandidate = RegExp(r'\bif\b');

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
