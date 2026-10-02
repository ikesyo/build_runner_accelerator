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
/// By default entries live in one packed file per SDK under the shared
/// accelerator cache directory (`store.v2.bin`), read through an in-memory
/// offset index — one file scan per worker instead of ~900 individual file
/// opens during the dep walk. With
/// `BUILD_RUNNER_ACCELERATOR_PACKED_STORE=0` the legacy layout is used: small
/// JSON files, one per key. Both layouts are namespaced by the running SDK
/// version because directive parsing is grammar-dependent. Because the key
/// binds the exact content, a stale entry can never be selected: any content
/// change produces a different key. A corrupt or unreadable entry is treated
/// as a miss and falls back to parsing.
///
/// Disable with `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0`.
final class AssetDepsCache {
  AssetDepsCache._(this._dir, this._packed);

  static const _version = 'v1';
  static const _packedVersion = 'v2';

  /// The shared process-wide cache, or `null` when disabled.
  static AssetDepsCache? shared() {
    final env = Platform.environment['BUILD_RUNNER_ACCELERATOR_DEP_CACHE'];
    if (env == '0') return null;
    final sdk = Platform.version.split(' ').first;
    final packed =
        Platform.environment['BUILD_RUNNER_ACCELERATOR_PACKED_STORE'] != '0';
    if (packed) {
      return AssetDepsCache._(
        Directory(
          p.join(
            acceleratorCacheDirectory(),
            'dep_parse',
            '$_packedVersion-$sdk',
          ),
        ),
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
    return AssetDepsCache._(
      Directory(
        p.join(acceleratorCacheDirectory(), 'dep_parse', '$_version-$sdk'),
      ),
      null,
    );
  }

  final Directory _dir;
  final IndexedBlobStore? _packed;

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
  String keyForDigest(AssetId id, String contentDigest) =>
      '$id\n$contentDigest';

  AssetDeps? lookup(String key) {
    final packed = _packed;
    if (packed != null) {
      final bytes = packed.get(key);
      if (bytes == null) return null;
      try {
        final text = utf8.decode(bytes);
        if (text.isEmpty) return AssetDeps(const <AssetId>[]);
        return AssetDeps(text.split('\n').map(AssetId.parse));
      } on Object {
        return null;
      }
    }
    try {
      final file = File(p.join(_dir.path, '$key.json'));
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      final deps = (decoded as Map<String, dynamic>)['d'] as List<dynamic>;
      return AssetDeps(deps.map((d) => AssetId.parse(d as String)));
    } on Object {
      return null;
    }
  }

  void store(String key, AssetDeps deps) {
    final packed = _packed;
    if (packed != null) {
      final ids = deps.deps.map((id) => id.toString()).join('\n');
      packed.put(key, utf8.encode(ids));
      return;
    }
    try {
      _dir.createSync(recursive: true);
      final payload = jsonEncode(<String, Object>{
        'd': deps.deps.map((id) => id.toString()).toList(),
      });
      // Unique temp name + rename so concurrent workers writing the same key
      // never observe a torn file; writers always produce identical bytes.
      final temp = File(p.join(_dir.path, '.$key.${pid}.tmp'));
      temp.writeAsStringSync(payload);
      temp.renameSync(p.join(_dir.path, '$key.json'));
    } on Object {
      // A cache write failure must never break the build.
    }
  }
}
