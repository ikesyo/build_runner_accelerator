import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/asset_deps.dart';
import 'package:build_runner_accelerator/src/asset_deps_cache.dart';
import 'package:crypto/crypto.dart';

void main(List<String> args) {
  if (args.contains('disabled')) {
    if (AssetDepsCache.shared() != null) {
      throw StateError('DEP_CACHE=0 did not disable the cache');
    }
    return;
  }
  final cache = AssetDepsCache.shared()!;
  final id = AssetId('app', 'lib/nested/model.dart');
  final key = cache.keyForDigest(id, '0123456789abcdef');
  final dep = AssetId('app', 'lib/dependency.dart');
  if (args.contains('unavailable')) {
    cache.store(key, AssetDeps([dep]));
    if (cache.lookup(key) != null) {
      throw StateError('An unavailable cache must be a miss');
    }
    return;
  }
  // Poison both retired per-key namespaces with a valid but wrong dependency.
  final sdk = Platform.version.split(' ').first;
  final oldKey = sha256.convert(utf8.encode('$id\n0123456789abcdef'));
  final oldFiles = [
    for (final version in ['v1', 'per-key-v1'])
      File(
        '${Platform.environment['BUILD_RUNNER_ACCELERATOR_CACHE']}'
        '/dep_parse/$version-$sdk/$oldKey.json',
      ),
  ];
  const oldPayload = '{"d":["app|lib/wrong.dart"]}';
  for (final file in oldFiles) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(oldPayload);
  }
  if (cache.lookup(key) != null) {
    throw StateError('A retired per-key entry was selected');
  }
  cache.store(key, AssetDeps([dep]));
  final reopened = AssetDepsCache.shared()!;
  if (reopened.lookup(key)?.deps.single != dep) {
    throw StateError('Digest-keyed dependency cache did not persist');
  }
  if (oldFiles.any((file) => file.readAsStringSync() != oldPayload)) {
    throw StateError('A retired cache entry was changed or removed');
  }
}
