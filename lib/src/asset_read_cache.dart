import 'dart:collection';
import 'dart:typed_data';

import 'package:build/build.dart';
import 'package:crypto/crypto.dart';

import 'blake3.dart';

/// Owned, immutable bytes and their lazily computed content-only BLAKE3.
/// Public builder reads receive copies; neither input buffers nor callers can
/// mutate the bytes after the digest has been computed.
final class AssetReadContent {
  AssetReadContent(List<int> bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  /// Wraps an already-owned, unshared [Uint8List] without copying it again.
  ///
  /// Callers must transfer exclusive ownership of [bytes] and its backing
  /// buffer so neither callers nor future reads can mutate the cached snapshot.
  AssetReadContent.owned(Uint8List bytes) : bytes = bytes.asUnmodifiableView();

  final Uint8List bytes;
  String? _digest;

  String? get cachedContentDigest => _digest;

  String get contentDigest => _digest ??= blake3Hex(bytes);

  /// Uncached build_runner-compatible MD5 of content followed by asset ID.
  Digest digestFor(AssetId id) {
    final result = _DigestSink();
    md5.startChunkedConversion(result)
      ..add(bytes)
      // Preserve codeUnits: UTF-8 would change the existing digest input.
      ..add(id.toString().codeUnits)
      ..close();
    return result.value;
  }
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Replacing/removing/clearing bytes also replaces/removes their digest.
/// Existing worker build/reset invalidation therefore governs both together.
final class AssetReadCache extends MapBase<AssetId, List<int>> {
  AssetReadCache([Map<AssetId, List<int>> initial = const {}]) {
    addAll(initial);
  }

  final _contents = <AssetId, AssetReadContent>{};

  AssetReadContent? contentFor(AssetId id) => _contents[id];

  /// Stores an exclusively owned [Uint8List] without an extra defensive copy.
  AssetReadContent putOwned(AssetId key, Uint8List value) {
    final content = AssetReadContent.owned(value);
    _contents[key] = content;
    return content;
  }

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
