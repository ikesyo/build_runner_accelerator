import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:build/build.dart';
import 'package:build_runner/src/io/asset_finder.dart' show AssetFinder;
import 'package:build_runner/src/io/asset_path_provider.dart'
    show AssetPathProvider;
import 'package:build_runner/src/io/filesystem.dart' show IoFilesystem;
import 'package:build_runner/src/io/reader_writer.dart' show ReaderWriter;
import 'package:crypto/crypto.dart';
import 'package:glob/glob.dart';

import 'protocol.dart';

/// Mutable per-action state behind the long-lived current build_runner
/// [ReaderWriter]. The Rust side processes a worker's batch sequentially, so
/// changing the action view between requests is safe and lets the same
/// [BuilderFilesystem] remain attached to the resolver's analysis model.
class _RemoteIoState {
  _RemoteIoState({required this.readCache, required this.readableCache});

  final Map<AssetId, List<int>> readCache;
  final Set<AssetId> readableCache;

  RpcSession? rpc;
  String package = '';
  AssetId? primaryInput;
  Set<AssetId> blockedAssets = <AssetId>{};
  final Map<AssetId, Uint8List> outputs = <AssetId, Uint8List>{};
  final Set<AssetId> observedReads = <AssetId>{};
  final Set<AssetId> observedGlobResults = <AssetId>{};
  final Set<ObservedGlob> observedGlobs = <ObservedGlob>{};

  void beginAction({
    required RpcSession rpc,
    required String package,
    required AssetId? primaryInput,
    required Set<AssetId> blockedAssets,
  }) {
    this.rpc = rpc;
    this.package = package;
    this.primaryInput = primaryInput;
    this.blockedAssets = blockedAssets;
    outputs.clear();
    observedReads.clear();
    observedGlobResults.clear();
    observedGlobs.clear();
  }

  RpcSession get activeRpc => rpc ?? (throw StateError('Remote IO is idle'));
}

/// A current build_runner [ReaderWriter] whose file operations are served by
/// the Rust frontend through the existing asset RPC protocol.
class RemoteAssetReaderWriter extends ReaderWriter {
  factory RemoteAssetReaderWriter({
    required Map<AssetId, List<int>> readCache,
    required Set<AssetId> readableCache,
  }) {
    final state = _RemoteIoState(
      readCache: readCache,
      readableCache: readableCache,
    );
    return RemoteAssetReaderWriter._(state);
  }

  RemoteAssetReaderWriter._(this._state)
    : super.using(
        assetFinder: _RemoteAssetFinder(_state),
        assetPathProvider: const _RemoteAssetPathProvider(),
        filesystem: IoFilesystem(),
      );

  final _RemoteIoState _state;

  Map<AssetId, Uint8List> get outputs => _state.outputs;
  Set<AssetId> get observedReads => _state.observedReads;
  Set<AssetId> get observedGlobResults => _state.observedGlobResults;
  Set<ObservedGlob> get observedGlobs => _state.observedGlobs;

  void beginAction({
    required RpcSession rpc,
    required String package,
    required AssetId? primaryInput,
    required Set<AssetId> blockedAssets,
  }) => _state.beginAction(
    rpc: rpc,
    package: package,
    primaryInput: primaryInput,
    blockedAssets: blockedAssets,
  );

  @override
  Future<bool> canRead(AssetId id, {bool inArtifactTree = false}) async {
    _state.observedReads.add(id);
    final primaryInput = _state.primaryInput;
    if (primaryInput != null && id != primaryInput) return false;
    if (_state.outputs.containsKey(id)) return true;
    if (_isBlocked(id)) return false;
    if (_state.readCache.containsKey(id) || _state.readableCache.contains(id)) {
      return true;
    }
    final response = await _state.activeRpc.call('can_read', <String, dynamic>{
      'asset': id.toString(),
    });
    final value = response['value'] == true;
    if (value) _state.readableCache.add(id);
    return value;
  }

  @override
  Future<Digest> digest(AssetId id, {bool inArtifactTree = false}) async {
    _state.observedReads.add(id);
    final bytes = await readAsBytes(id, inArtifactTree: inArtifactTree);
    return md5.convert(<int>[...bytes, ...id.toString().codeUnits]);
  }

  @override
  Stream<AssetId> findAssets(Glob glob) =>
      assetFinder.find(glob, package: _state.package);

  @override
  Future<List<int>> readAsBytes(
    AssetId id, {
    bool inArtifactTree = false,
  }) async {
    _state.observedReads.add(id);
    final primaryInput = _state.primaryInput;
    if (primaryInput != null && id != primaryInput) {
      throw AssetNotFoundException(id);
    }
    final local = _state.outputs[id];
    if (local != null) return List<int>.from(local);
    if (_isBlocked(id)) throw AssetNotFoundException(id);
    final cached = _state.readCache[id];
    if (cached != null) return List<int>.from(cached);
    try {
      final response = await _state.activeRpc.call('read', <String, dynamic>{
        'asset': id.toString(),
      });
      final rawBytes = response['bytes'];
      if (rawBytes is! List) {
        throw const FormatException('Asset read response bytes must be a list');
      }
      final bytes = rawBytes is Uint8List
          ? rawBytes
          : Uint8List.fromList(List<int>.from(rawBytes));
      _state.readCache[id] = bytes;
      return List<int>.from(bytes);
    } on StateError catch (error) {
      if (error.message.toString().contains('asset not found')) {
        throw AssetNotFoundException(id);
      }
      rethrow;
    }
  }

  @override
  Future<String> readAsString(
    AssetId id, {
    Encoding encoding = utf8,
    bool inArtifactTree = false,
  }) async =>
      encoding.decode(await readAsBytes(id, inArtifactTree: inArtifactTree));

  @override
  Future<void> writeAsBytes(
    AssetId id,
    List<int> bytes, {
    bool inArtifactTree = false,
  }) async {
    _state.outputs[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> writeAsString(
    AssetId id,
    String contents, {
    Encoding encoding = utf8,
    bool inArtifactTree = false,
  }) => writeAsBytes(
    id,
    encoding.encode(contents),
    inArtifactTree: inArtifactTree,
  );

  bool _isBlocked(AssetId id) => _state.blockedAssets.contains(id);
}

class _RemoteAssetFinder implements AssetFinder {
  _RemoteAssetFinder(this._state);

  final _RemoteIoState _state;

  @override
  Stream<AssetId> find(Glob glob, {required String package}) async* {
    final requestedPackage = package;
    _state.observedGlobs.add(
      ObservedGlob(package: requestedPackage, pattern: glob.pattern),
    );
    final response = await _state.activeRpc.call(
      'find_assets',
      <String, dynamic>{'package': requestedPackage, 'pattern': glob.pattern},
    );
    final assets = response['assets'];
    if (assets is! List) {
      throw const FormatException('Asset find response assets must be a list');
    }
    for (final rawAsset in assets) {
      final id = AssetId.parse(rawAsset as String);
      if (_isBlocked(id)) continue;
      _state.observedGlobResults.add(id);
      yield id;
    }
  }

  bool _isBlocked(AssetId id) => _state.blockedAssets.contains(id);
}

class _RemoteAssetPathProvider implements AssetPathProvider {
  const _RemoteAssetPathProvider();

  @override
  String pathFor(
    AssetId id, {
    required bool inArtifactTree,
    bool checkWriteAllowed = false,
  }) => '/${id.package}/${id.path}';
}

class ObservedGlob {
  const ObservedGlob({required this.package, required this.pattern});

  final String package;
  final String pattern;

  @override
  bool operator ==(Object other) =>
      other is ObservedGlob &&
      other.package == package &&
      other.pattern == pattern;

  @override
  int get hashCode => Object.hash(package, pattern);
}

class RemotePostProcessBuildStep implements PostProcessBuildStep {
  RemotePostProcessBuildStep({
    required this.inputId,
    required this.io,
    required void Function(AssetId) deletePrimaryInput,
  }) : _deletePrimaryInput = deletePrimaryInput;

  @override
  final AssetId inputId;
  final RemoteAssetReaderWriter io;
  final void Function(AssetId) _deletePrimaryInput;

  @override
  Future<Digest> digest(AssetId id) async {
    if (id != inputId) throw InvalidInputException(id);
    return io.digest(id);
  }

  @override
  Future<List<int>> readInputAsBytes() => io.readAsBytes(inputId);

  @override
  Future<String> readInputAsString({Encoding encoding = utf8}) =>
      io.readAsString(inputId, encoding: encoding);

  @override
  Future<void> writeAsBytes(AssetId id, FutureOr<List<int>> bytes) async {
    await io.writeAsBytes(id, await bytes);
  }

  @override
  Future<void> writeAsString(
    AssetId id,
    FutureOr<String> content, {
    Encoding encoding = utf8,
  }) async {
    await io.writeAsString(id, await content, encoding: encoding);
  }

  @override
  void deletePrimaryInput() => _deletePrimaryInput(inputId);

  @override
  Future<void> complete() async {}
}
