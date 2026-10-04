import 'dart:collection';
import 'dart:typed_data';

import 'package:build/build.dart';
import 'package:crypto/crypto.dart';

/// Owned, immutable bytes and their lazily computed content-only SHA-256.
/// Public builder reads receive copies; neither input buffers nor callers can
/// mutate the bytes after the digest has been computed.
final class AssetReadContent {
  AssetReadContent(List<int> bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final Uint8List bytes;
  String? _digest;

  String? get cachedContentDigest => _digest;

  String get contentDigest => _digest ??= sha256.convert(bytes).toString();
}

/// Replacing/removing/clearing bytes also replaces/removes their digest.
/// Existing worker build/reset invalidation therefore governs both together.
final class AssetReadCache extends MapBase<AssetId, List<int>> {
  AssetReadCache([Map<AssetId, List<int>> initial = const {}]) {
    addAll(initial);
  }

  final _contents = <AssetId, AssetReadContent>{};

  AssetReadContent? contentFor(AssetId id) => _contents[id];

  @override
  List<int>? operator [](Object? key) => _contents[key]?.bytes;

  @override
  void operator []=(AssetId key, List<int> value) {
    _contents[key] = AssetReadContent(value);
  }

  @override
  Iterable<AssetId> get keys => _contents.keys;

  @override
  bool containsKey(Object? key) => _contents.containsKey(key);

  @override
  List<int>? remove(Object? key) => _contents.remove(key)?.bytes;

  @override
  void clear() => _contents.clear();
}
