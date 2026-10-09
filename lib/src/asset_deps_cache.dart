import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/asset_deps.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'cache_directory.dart';
import 'indexed_blob_store.dart';

/// Content-keyed cache of parsed import/export/part dependencies.
///
/// Every worker's `LibraryCycleGraphLoader` walk parses each transitively
/// imported file with `parseString` to recover its directive dependencies.
/// That parse is the dominant per-worker startup cost and is identical across
/// workers and builds: the result depends only on the file content and the
/// importing asset's id (needed for relative URI resolution). This cache keys
/// `AssetDeps` by `sha256(assetId + content)` so later workers and later
/// builds reuse it instead of re-parsing.
///
/// Entries live in one packed file per SDK under the shared
/// accelerator cache directory (`v3-<sdk>/store.bin`), read through an in-memory
/// offset index — one metadata scan per worker instead of ~900 individual file
/// opens during the dep walk. The store is namespaced by the running SDK
/// version because directive parsing is grammar-dependent. Because the key
/// binds the exact content, a stale entry can never be selected: any content
/// change produces a different key. A corrupt or unreadable entry is treated
/// as a miss and falls back to parsing.
///
/// Disable with `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0`.
final class AssetDepsCache {
  AssetDepsCache._(this._packed);

  static const _packedVersion = 'v3';

  /// The shared process-wide cache, or `null` when disabled.
  static AssetDepsCache? shared() {
    final env = Platform.environment['BUILD_RUNNER_ACCELERATOR_DEP_CACHE'];
    if (env == '0') return null;
    final sdk = Platform.version.split(' ').first;
    return AssetDepsCache._(
      IndexedBlobStore(
        p.join(
          acceleratorCacheDirectory(),
          'dep_parse',
          '$_packedVersion-$sdk',
          'store.bin',
        ),
      ),
    );
  }

  final IndexedBlobStore _packed;

  /// Cache key binding the importing asset and its exact content. Relative
  /// directive URIs resolve against [id], so identical content in different
  /// assets must not share an entry.
  String keyFor(AssetId id, String content) =>
      sha256.convert(utf8.encode('$id\n$content')).toString();

  /// Cache key reusing an already-computed content digest — the analyzer's
  /// own md5 `contentHash` — so the lookup path skips hashing ~8KB of source
  /// per dep file. Callers must only pass a digest that provably covers the
  /// same content; the returned key binds [id] exactly like [keyFor] and
  /// shares the same key space.
  String keyForDigest(AssetId id, String contentDigest) {
    return '$id\n$contentDigest';
  }

  AssetDeps? lookup(String key) {
    final bytes = _packed.get(key);
    if (bytes == null) return null;
    try {
      final text = utf8.decode(bytes);
      if (text.isEmpty) return AssetDeps(const <AssetId>[]);
      return AssetDeps(text.split('\n').map(AssetId.parse));
    } on Object {
      return null;
    }
  }

  void store(String key, AssetDeps deps) {
    final ids = deps.deps.map((id) => id.toString()).join('\n');
    _packed.put(key, utf8.encode(ids));
  }
}
