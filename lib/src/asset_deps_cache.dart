import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/asset_deps.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'cache_directory.dart';

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
/// Entries are stored as small JSON files under the shared accelerator cache
/// directory, namespaced by the running SDK version because directive parsing
/// is grammar-dependent. Because the key binds the exact content, a stale
/// entry can never be selected: any content change produces a different key.
/// A corrupt or unreadable entry is treated as a miss and falls back to
/// parsing.
///
/// Disable with `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0`.
final class AssetDepsCache {
  AssetDepsCache._(this._dir);

  static const _version = 'v1';

  /// The shared process-wide cache, or `null` when disabled.
  static AssetDepsCache? shared() {
    final env = Platform.environment['BUILD_RUNNER_ACCELERATOR_DEP_CACHE'];
    if (env == '0') return null;
    final sdk = Platform.version.split(' ').first;
    return AssetDepsCache._(
      Directory(
        p.join(acceleratorCacheDirectory(), 'dep_parse', '$_version-$sdk'),
      ),
    );
  }

  final Directory _dir;

  /// Cache key binding the importing asset and its exact content. Relative
  /// directive URIs resolve against [id], so identical content in different
  /// assets must not share an entry.
  String keyFor(AssetId id, String content) =>
      sha256.convert(utf8.encode('$id\n$content')).toString();

  AssetDeps? lookup(String key) {
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
