import 'package:build/build.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/library_cycle_graph/asset_deps.dart';
import 'package:build_runner_accelerator/src/asset_deps_cache.dart';

void main() {
  final cache = AssetDepsCache.shared()!;
  final id = AssetId('app', 'lib/nested/model.dart');
  final key = cache.keyForDigest(id, '0123456789abcdef');
  final dep = AssetId('app', 'lib/dependency.dart');
  cache.store(key, AssetDeps([dep]));
  final reopened = AssetDepsCache.shared()!;
  if (reopened.lookup(key)?.deps.single != dep) {
    throw StateError('Digest-keyed dependency cache did not persist');
  }
}
