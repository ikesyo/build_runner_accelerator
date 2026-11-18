import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'frontend_binary_resolver.dart' show buildRunnerAcceleratorVersion;

typedef JsonMap = Map<String, dynamic>;
typedef RpcControlMessageHandler =
    Future<void> Function(WorkerBuildRequest message);

const List<int> _binaryAssetResponseMagic = <int>[0x42, 0x52, 0x41, 0x42];
const List<int> _binaryBuildResultMagic = <int>[0x42, 0x52, 0x41, 0x52];
const int _maxFrameLength = 256 * 1024 * 1024;

/// Typed messages received by the resident worker from the Rust frontend.
///
/// JSON is decoded and validated once at the IPC boundary. The execution
/// layer should consume these values instead of repeatedly inspecting maps.
sealed class WorkerMessage {
  const WorkerMessage({required this.id});

  final Object? id;

  static WorkerMessage decode(
    JsonMap message, {
    List<String>? previousBatchBlockedAssets,
    List<String>? assetDictionary,
  }) {
    validateProtocolVersion(message);
    switch (message['type']) {
      case 'initialize':
        return WorkerInitializeMessage.fromJson(message);
      case 'reset':
        return WorkerResetMessage.fromJson(message);
      case 'reset_resolver':
        return WorkerResetResolverMessage.fromJson(
          message,
          dictionary: _messageDictionary(message, assetDictionary),
        );
      case 'build':
        return WorkerBuildMessage(_decodeBuildRequest(message));
      case 'build_batch':
        return WorkerBuildBatchMessage.fromJson(
          message,
          previousBlockedAssets: previousBatchBlockedAssets,
          dictionary: _messageDictionary(message, assetDictionary),
        );
      default:
        return UnsupportedWorkerMessage(
          id: message['id'],
          type: message['type'],
        );
    }
  }
}

class WorkerInitializeMessage extends WorkerMessage {
  WorkerInitializeMessage({
    required int id,
    required this.package,
    required this.root,
    required this.phaseCount,
    required this.inputRestrictions,
    this.retainedOutputGuard = false,
  }) : super(id: id);

  factory WorkerInitializeMessage.fromJson(JsonMap message) {
    if (message['accelerator_version'] != buildRunnerAcceleratorVersion) {
      throw const FormatException('initialize accelerator_version mismatch');
    }
    final phaseCount = _requiredInt(message, 'phase_count', 'initialize');
    if (phaseCount < 1) {
      throw const FormatException('initialize phase_count must be positive');
    }
    final root = _requiredString(message, 'root', 'initialize');
    if (!Directory(root).isAbsolute ||
        message['resolver_mode'] != 'dart_local') {
      throw const FormatException(
        'initialize requires absolute root and dart_local resolver_mode',
      );
    }
    final package = _requiredString(message, 'package', 'initialize');
    if (package.isEmpty) {
      throw const FormatException('initialize requires a non-empty package');
    }
    return WorkerInitializeMessage(
      id: _requiredInt(message, 'id', 'initialize'),
      package: package,
      root: root,
      phaseCount: phaseCount,
      inputRestrictions: {
        for (final entry in _stringKeyedMap(
          message['input_restrictions'],
          'initialize input_restrictions',
        ).entries)
          entry.key: _stringList(entry.value, 'input restriction patterns'),
      },
      retainedOutputGuard: message.containsKey('retained_output_guard')
          ? _requiredBool(message, 'retained_output_guard', 'initialize')
          : false,
    );
  }

  final String package;
  final String root;
  final int phaseCount;
  final Map<String, List<String>> inputRestrictions;
  final bool retainedOutputGuard;
}

class WorkerResetMessage extends WorkerMessage {
  WorkerResetMessage({required int id}) : super(id: id);

  factory WorkerResetMessage.fromJson(JsonMap message) =>
      WorkerResetMessage(id: _requiredInt(message, 'id', 'reset'));
}

class WorkerResetResolverMessage extends WorkerMessage {
  /// Describes a committed phase delta and its explicit blob/memory transport.
  WorkerResetResolverMessage({
    required int id,
    required this.updatedSources,
    required this.deletedSources,
    required this.updatedCache,
    required this.deletedCache,
    required this.incremental,
    required this.overlayBlob,
  }) : super(id: id);

  /// Assets whose overlay content changed since the last phase commit.
  final List<String> updatedSources;

  /// Assets removed from the overlay since the last phase commit.
  final List<String> deletedSources;

  /// Changed cache-tree assets. These are applied to the worker's asset view
  /// and generated Dart/part files remain Analyzer-visible.
  final List<String> updatedCache;

  /// Cache-tree assets removed from the overlay.
  final List<String> deletedCache;

  /// Whether the worker may keep its resolver state and apply source changes
  /// incrementally. False when a clean resolver rebuild is required.
  final bool incremental;

  /// Required reset-scoped transport descriptor; null uses single-worker memory.
  final Map<String, Object?>? overlayBlob;

  /// Validates required reset fields and normalizes the nullable descriptor.
  factory WorkerResetResolverMessage.fromJson(
    JsonMap message, {
    List<String>? dictionary,
  }) {
    if (!message.containsKey('overlay_blob')) {
      throw const FormatException('reset_resolver requires overlay_blob');
    }
    final overlayBlob = message['overlay_blob'];
    return WorkerResetResolverMessage(
      id: _requiredInt(message, 'id', 'reset_resolver'),
      updatedSources: _assetList(
        message['updated_sources'],
        dictionary,
        'reset_resolver updated_sources',
      ),
      deletedSources: _assetList(
        message['deleted_sources'],
        dictionary,
        'reset_resolver deleted_sources',
      ),
      updatedCache: _assetList(
        message['updated_cache'],
        dictionary,
        'reset_resolver updated_cache',
      ),
      deletedCache: _assetList(
        message['deleted_cache'],
        dictionary,
        'reset_resolver deleted_cache',
      ),
      incremental: _requiredBool(message, 'incremental', 'reset_resolver'),
      overlayBlob: overlayBlob == null
          ? null
          : _resolveOverlayBlob(
              _jsonMap(overlayBlob, 'reset_resolver overlay_blob'),
              dictionary,
            ),
    );
  }
}

class WorkerBuildMessage extends WorkerMessage {
  WorkerBuildMessage(this.request) : super(id: request.id);

  final WorkerBuildRequest request;
}

class WorkerBuildBatchMessage extends WorkerMessage {
  /// The visibility hint is shared by every child request in the batch.
  WorkerBuildBatchMessage({
    required int id,
    required this.blockedAssets,
    required this.requests,
    this.assetDigestUpdates = const <String, String?>{},
  }) : super(id: id);

  factory WorkerBuildBatchMessage.fromJson(
    JsonMap message, {
    List<String>? previousBlockedAssets,
    List<String>? dictionary,
  }) {
    final reuse = message.containsKey('blocked_assets_reuse')
        ? _requiredBool(message, 'blocked_assets_reuse', 'build_batch')
        : false;
    final suppliedAssets = _assetList(
      message['blocked_assets'],
      dictionary,
      'build_batch blocked_assets',
    );
    if (reuse && (previousBlockedAssets == null || suppliedAssets.isNotEmpty)) {
      throw const FormatException(
        'blocked_assets_reuse requires a prior batch list and an empty list',
      );
    }
    final blockedAssets = reuse
        ? previousBlockedAssets!
        : List<String>.unmodifiable(suppliedAssets);
    final rawRequests = message['requests'];
    if (rawRequests is! List) {
      throw const FormatException('build_batch requests must be a list');
    }
    final rawShared = message['shared'];
    final sharedFields = rawShared == null
        ? null
        : _jsonMap(rawShared, 'build_batch shared');
    final requests = [
      for (final rawRequest in rawRequests)
        WorkerBuildRequest.fromJson(
          sharedFields == null
              ? _jsonMap(rawRequest, 'build_batch request')
              : <String, dynamic>{
                  ...sharedFields,
                  ..._jsonMap(rawRequest, 'build_batch request'),
                },
          blockedAssets: blockedAssets,
          dictionary: dictionary,
        ),
    ];
    if (requests.isNotEmpty &&
        requests.any(
          (request) =>
              request.phase != requests.first.phase ||
              request.kind != requests.first.kind,
        )) {
      throw const FormatException(
        'build_batch requires one phase and builder kind',
      );
    }
    return WorkerBuildBatchMessage(
      id: _requiredInt(message, 'id', 'build_batch'),
      blockedAssets: blockedAssets,
      requests: requests,
      assetDigestUpdates: _assetDigestUpdates(
        message['asset_digests'],
        dictionary,
      ),
    );
  }

  final List<String> blockedAssets;
  final List<WorkerBuildRequest> requests;

  /// The `asset-digests-v1` delta carried by this batch, keyed by asset
  /// id: a digest string updates the worker's digest map, a null removes
  /// the id. Empty when the message carries no delta. See ADR 0054.
  final Map<String, String?> assetDigestUpdates;
}

class UnsupportedWorkerMessage extends WorkerMessage {
  const UnsupportedWorkerMessage({required super.id, required this.type});

  final Object? type;
}

/// A validated build request, including nested optional-build requests.
class WorkerBuildRequest {
  WorkerBuildRequest({
    required this.id,
    required this.builder,
    required this.input,
    required this.kind,
    required this.allowedOutputs,
    required this.options,
    required this.phase,
    required this.instanceKey,
    required this.isRoot,
    required this.blockedAssets,
    required this.triggers,
    this.partPhaseIndex,
    this.traceparent,
    this.otelReportId,
    this.apiCutoff = false,
  });

  factory WorkerBuildRequest.fromJson(
    JsonMap message, {
    required List<String> blockedAssets,
    List<String>? dictionary,
  }) {
    final kind = _requiredString(message, 'kind', 'build');
    if (kind != 'normal' && kind != 'post_process') {
      throw FormatException('unsupported build kind: $kind');
    }
    final instanceKey = _requiredString(message, 'instance_key', 'build');
    final phase = _requiredInt(message, 'phase', 'build');
    final partPhaseIndex = message['part_phase_index'];
    if (partPhaseIndex != null &&
        (partPhaseIndex is! int || partPhaseIndex < 0 || kind != 'normal')) {
      throw const FormatException(
        'build part_phase_index requires a nonnegative normal-builder phase',
      );
    }
    if (instanceKey.isEmpty || phase < 0) {
      throw const FormatException(
        'build requires non-empty instance_key and nonnegative phase',
      );
    }
    return WorkerBuildRequest(
      id: _requiredInt(message, 'id', 'build'),
      builder: _requiredString(message, 'builder', 'build'),
      input: dictionary == null
          ? _requiredString(message, 'input', 'build')
          : _resolveAssetRef(message['input'], dictionary, 'build input'),
      kind: kind,
      allowedOutputs: _assetList(
        message['allowed_outputs'],
        dictionary,
        'build allowed_outputs',
      ),
      options: _stringKeyedMap(message['options'], 'build options'),
      phase: phase,
      partPhaseIndex: partPhaseIndex as int?,
      instanceKey: instanceKey,
      isRoot: _requiredBool(message, 'is_root', 'build'),
      apiCutoff: message.containsKey('api_cutoff')
          ? _requiredBool(message, 'api_cutoff', 'build')
          : false,
      blockedAssets: blockedAssets,
      triggers: _triggerList(message['triggers'], 'build triggers'),
      otelReportId:
          message['otel_report_id'] is int &&
              (message['otel_report_id'] as int) > 0
          ? message['otel_report_id'] as int
          : null,
      traceparent: message['traceparent'] is String
          ? message['traceparent'] as String
          : null,
    );
  }

  final int id;
  final String builder;
  final String input;
  final String kind;
  final List<String> allowedOutputs;
  final Map<String, dynamic> options;
  final int phase;
  final String instanceKey;
  final bool isRoot;
  final List<String> blockedAssets;
  final List<WorkerBuildTrigger> triggers;
  final int? partPhaseIndex;
  final String? traceparent;
  final int? otelReportId;

  /// Whether the builder opted into API-signature early cutoff
  /// (ADR 0056). Carried for the result assembly; recording and
  /// classification do not depend on it yet.
  final bool apiCutoff;

  bool get isPostProcess => kind == 'post_process';
}

class WorkerBuildTrigger {
  const WorkerBuildTrigger({required this.kind, required this.value});

  factory WorkerBuildTrigger.fromJson(Object? raw) {
    final message = _jsonMap(raw, 'build trigger');
    return WorkerBuildTrigger(
      kind: _requiredString(message, 'kind', 'build trigger'),
      value: _requiredString(message, 'value', 'build trigger'),
    );
  }

  final String kind;
  final String value;
}

void validateProtocolVersion(JsonMap message) {
  if (message['v'] is! int || message['v'] != 1) {
    throw const FormatException('unsupported or missing IPC protocol version');
  }
}

int _requiredInt(JsonMap message, String key, String type) {
  final value = message[key];
  if (value is! int) {
    throw FormatException('$type requires an integer $key');
  }
  return value;
}

bool _requiredBool(JsonMap message, String key, String type) {
  final value = message[key];
  if (value is! bool) {
    throw FormatException('$type requires a boolean $key');
  }
  return value;
}

String _requiredString(JsonMap message, String key, String type) =>
    _requiredStringValue(message[key], '$type $key');

String _requiredStringValue(Object? value, String label) {
  if (value is! String) {
    throw FormatException('$label must be a string');
  }
  return value;
}

JsonMap _jsonMap(Object? value, String label) {
  if (value is! Map) {
    throw FormatException('$label must be an object');
  }
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$label keys must be strings');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, dynamic> _stringKeyedMap(Object? value, String label) =>
    _jsonMap(value, label);

List<String> _stringList(Object? value, String label) {
  if (value is! List) {
    throw FormatException('$label must be a list');
  }
  return [for (final item in value) _requiredStringValue(item, '$label item')];
}

/// Applies a message's `asset_dict_add` list to the connection dictionary
/// and returns the dictionary to resolve this message's id references
/// with, or null when the message uses the plain string form. The
/// additions are appended before any other field is interpreted, matching
/// the sender's encoding order. See ADR 0053.
List<String>? _messageDictionary(JsonMap message, List<String>? dictionary) {
  if (!message.containsKey('asset_dict_add')) return null;
  if (dictionary == null) {
    throw const FormatException(
      'asset_dict_add requires a worker asset dictionary',
    );
  }
  dictionary.addAll(_stringList(message['asset_dict_add'], 'asset_dict_add'));
  return dictionary;
}

String _resolveAssetRef(Object? value, List<String> dictionary, String label) {
  if (value is! int || value < 0 || value >= dictionary.length) {
    throw FormatException('$label requires an in-range dictionary index');
  }
  return dictionary[value];
}

/// Decodes an `asset_digests` delta in either form: keyed by asset id, or
/// by decimal dictionary index when [dictionary] is the message's active
/// dictionary. Values are digest strings, or null for a removal.
Map<String, String?> _assetDigestUpdates(
  Object? value,
  List<String>? dictionary,
) {
  if (value == null) return const <String, String?>{};
  if (value is! Map) {
    throw const FormatException('build_batch asset_digests must be an object');
  }
  final updates = <String, String?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException(
        'build_batch asset_digests key must be a string',
      );
    }
    final asset = dictionary == null
        ? key
        : _resolveAssetRef(
            int.tryParse(key),
            dictionary,
            'build_batch asset_digests key',
          );
    final digest = entry.value;
    if (digest != null && digest is! String) {
      throw const FormatException(
        'build_batch asset_digests value must be a string or null',
      );
    }
    updates[asset] = digest as String?;
  }
  return updates;
}

/// Decodes an asset id list in either form: plain strings, or dictionary
/// indexes when [dictionary] is the message's active dictionary.
List<String> _assetList(Object? value, List<String>? dictionary, String label) {
  if (dictionary == null) return _stringList(value, label);
  if (value is! List) {
    throw FormatException('$label must be a list');
  }
  return [
    for (final item in value) _resolveAssetRef(item, dictionary, '$label item'),
  ];
}

/// Rewrites an interned overlay blob descriptor's `index` keys, which are
/// decimal dictionary indexes, back to asset ids. Other descriptors and
/// fields pass through unchanged.
Map<String, Object?> _resolveOverlayBlob(
  Map<String, Object?> blob,
  List<String>? dictionary,
) {
  if (dictionary == null) return blob;
  final index = blob['index'];
  if (index is! Map) return blob;
  final resolved = <String, dynamic>{
    for (final entry in index.entries)
      _resolveAssetRef(
        int.tryParse('${entry.key}'),
        dictionary,
        'reset_resolver overlay_blob index key',
      ): entry.value,
  };
  return <String, Object?>{...blob, 'index': resolved};
}

List<WorkerBuildTrigger> _triggerList(Object? value, String label) {
  if (value is! List) {
    throw FormatException('$label must be a list');
  }
  return [for (final item in value) WorkerBuildTrigger.fromJson(item)];
}

class FrameReader {
  FrameReader(Stream<List<int>> input) : _iterator = StreamIterator(input);

  static final _emptyBuffer = Uint8List(0);
  static const _headerLength = 4;
  final StreamIterator<List<int>> _iterator;
  Uint8List _buffer = _emptyBuffer;
  int _start = 0;
  int _end = 0;

  int get _available => _end - _start;

  Future<JsonMap?> next() async {
    if (_available < _headerLength) await _fill(_headerLength);
    if (_available == 0) return null;

    final length = ByteData.sublistView(_buffer).getUint32(_start, Endian.big);
    if (length > _maxFrameLength) {
      throw const FormatException('IPC frame exceeds the 256 MiB safety limit');
    }
    final frameLength = _headerLength + length;
    if (_available < frameLength) await _fill(frameLength);
    final payload = _buffer.sublist(
      _start + _headerLength,
      _start + frameLength,
    );
    _start += frameLength;
    if (_start == _end) {
      _buffer = _emptyBuffer;
      _start = _end = 0;
    }
    if (_hasBinaryAssetResponseMagic(payload)) {
      return _decodeBinaryAssetResponse(payload);
    }
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map) {
      throw FormatException('IPC payload must be a JSON object');
    }
    return decoded.cast<String, dynamic>();
  }

  bool _hasBinaryAssetResponseMagic(Uint8List payload) {
    if (payload.length < _binaryAssetResponseMagic.length) return false;
    for (var index = 0; index < _binaryAssetResponseMagic.length; index++) {
      if (payload[index] != _binaryAssetResponseMagic[index]) return false;
    }
    return true;
  }

  JsonMap _decodeBinaryAssetResponse(Uint8List payload) {
    const envelopeHeaderLength = 8;
    if (payload.length < envelopeHeaderLength) {
      throw const FormatException('Binary IPC envelope is truncated');
    }
    final metadataLength = ByteData.sublistView(
      payload,
      _binaryAssetResponseMagic.length,
      envelopeHeaderLength,
    ).getUint32(0, Endian.big);
    final bytesStart = envelopeHeaderLength + metadataLength;
    if (bytesStart > payload.length) {
      throw const FormatException('Binary IPC metadata is truncated');
    }

    final decoded = jsonDecode(
      utf8.decoder.convert(payload, envelopeHeaderLength, bytesStart),
    );
    if (decoded is! Map) {
      throw const FormatException('Binary IPC metadata must be a JSON object');
    }
    final message = <String, dynamic>{...decoded.cast<String, dynamic>()};
    if (message['type'] != 'asset_response' || message['encoding'] != 'raw') {
      throw const FormatException('Unsupported binary IPC envelope');
    }
    final expectedLength = message['length'];
    final actualLength = payload.length - bytesStart;
    if (expectedLength is! int || expectedLength != actualLength) {
      throw const FormatException('Binary IPC payload length mismatch');
    }
    // Keep the frame buffer alive through the view and defer the defensive
    // copy until a builder receives the bytes from the shared read cache.
    message['bytes'] = Uint8List.sublistView(payload, bytesStart);
    return message;
  }

  Future<void> _fill(int length) async {
    while (_available < length) {
      if (!await _iterator.moveNext()) {
        if (_available == 0) return;
        throw const FormatException('Unexpected EOF in IPC frame');
      }
      final chunk = _iterator.current;
      final chunkLength = chunk.length;
      if (_end + chunkLength > _buffer.length) {
        final available = _available;
        final required = available + chunkLength;
        // Grow only for bytes that arrived. Compact only when a read needs
        // more input and the free space at the end cannot fit the new chunk.
        final buffer = required <= _buffer.length
            ? _buffer
            : Uint8List(
                max(
                  required,
                  min(_buffer.length * 2, _maxFrameLength + _headerLength),
                ),
              );
        buffer.setRange(0, available, _buffer, _start);
        _buffer = buffer;
        _start = 0;
        _end = available;
      }
      _buffer.setRange(_end, _end + chunkLength, chunk);
      _end += chunkLength;
    }
  }
}

WorkerBuildRequest _decodeBuildRequest(JsonMap message) {
  return WorkerBuildRequest.fromJson(
    message,
    blockedAssets: _stringList(
      message['blocked_assets'],
      'build blocked_assets',
    ),
  );
}

class FrameWriter {
  FrameWriter(this._output, {int maxBuildResultFrameLength = _maxFrameLength})
    : _maxBuildResultFrameLength = maxBuildResultFrameLength {
    // A lower limit makes boundary tests cheap; callers cannot raise the
    // protocol's production safety limit.
    if (maxBuildResultFrameLength < 8 ||
        maxBuildResultFrameLength > _maxFrameLength) {
      throw RangeError.range(maxBuildResultFrameLength, 8, _maxFrameLength);
    }
  }

  final IOSink _output;
  final int _maxBuildResultFrameLength;
  Future<void> _pending = Future<void>.value();

  /// Enqueues a JSON frame without interleaving it with another send's flush.
  Future<void> send(JsonMap message) async {
    final payload = utf8.encode(jsonEncode(message));
    if (payload.length > _maxFrameLength) {
      throw StateError('IPC frame exceeds the 256 MiB safety limit');
    }
    final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
    await _sendChunks([header.buffer.asUint8List(), payload]);
  }

  Future<void> sendBuildResult(JsonMap message) async {
    final outputBytes = <Uint8List>[];
    final metadata = _binaryBuildResultMetadata(message, outputBytes);
    await _sendBinary(_binaryBuildResultMagic, metadata, outputBytes);
  }

  // Only oversized replies take this path. Keep the execution lease intact;
  // splitting results does not rerun builders or repeat batch preparation.
  Future<void> _sendSplitBatch(
    JsonMap message,
    List<Uint8List> outputBytes,
  ) async {
    if (message['type'] != 'build_batch_result' &&
        message['type'] != 'build_batch_chunk') {
      throw StateError('IPC frame exceeds the 256 MiB safety limit');
    }
    final results = message['results'] as List;
    final graph = _asJsonMap(message['dep_graph'], 'dependency graph');
    // Batch-level evidence (dep graph, API fingerprints) rides with
    // exactly one part; the other parts carry it empty so the
    // frontend's merge never sees a key twice.
    if (results.length > 1) {
      final middle = results.length ~/ 2;
      final rawMiddle = results
          .take(middle)
          .fold<int>(
            0,
            (count, item) => count + (item['outputs'] as List).length,
          );
      await _sendBatchPart({
        ...message,
        'results': results.sublist(0, middle),
        'dep_graph': <String, dynamic>{},
        // Blanked only when present: adding the key would grow a part
        // past the size the split was computed from.
        if (message.containsKey('api_fingerprints'))
          'api_fingerprints': <String, dynamic>{},
        'type': 'build_batch_chunk',
      }, outputBytes.sublist(0, rawMiddle));
      await _sendBatchPart({
        ...message,
        'results': results.sublist(middle),
      }, outputBytes.sublist(rawMiddle));
    } else if (results.isNotEmpty && graph.isNotEmpty) {
      await _sendBatchPart({
        ...message,
        'dep_graph': <String, dynamic>{},
        if (message.containsKey('api_fingerprints'))
          'api_fingerprints': <String, dynamic>{},
        'type': 'build_batch_chunk',
      }, outputBytes);
      await _sendBatchPart({...message, 'results': <dynamic>[]}, const []);
    } else if (graph.length > 1) {
      final entries = graph.entries.toList(growable: false);
      final middle = entries.length ~/ 2;
      await _sendBatchPart({
        ...message,
        'dep_graph': Map<String, dynamic>.fromEntries(entries.take(middle)),
        if (message.containsKey('api_fingerprints'))
          'api_fingerprints': <String, dynamic>{},
        'type': 'build_batch_chunk',
      }, const []);
      await _sendBatchPart({
        ...message,
        'dep_graph': Map<String, dynamic>.fromEntries(entries.skip(middle)),
      }, const []);
    } else {
      // An individual action result or dependency entry must itself fit.
      throw StateError('IPC frame exceeds the 256 MiB safety limit');
    }
  }

  Future<void> _sendBatchPart(JsonMap metadata, List<Uint8List> outputBytes) =>
      _sendBinary(_binaryBuildResultMagic, metadata, outputBytes);

  JsonMap _binaryBuildResultMetadata(
    JsonMap message,
    List<Uint8List> outputBytes,
  ) {
    final metadata = <String, dynamic>{...message, 'encoding': 'raw'};
    switch (message['type']) {
      case 'build_result':
        metadata['outputs'] = _binaryOutputDescriptors(
          message['outputs'],
          outputBytes,
        );
      case 'build_batch_result':
        final rawResults = message['results'];
        if (rawResults is! List) {
          throw const FormatException(
            'build_batch_result results must be a list',
          );
        }
        metadata['results'] = <JsonMap>[
          for (final rawResult in rawResults)
            _binaryBuildResultMetadata(
              _asJsonMap(rawResult, 'build result'),
              outputBytes,
            ),
        ];
      default:
        throw FormatException(
          'Unsupported binary build result type: ${message['type']}',
        );
    }
    return metadata;
  }

  List<JsonMap> _binaryOutputDescriptors(
    dynamic rawOutputs,
    List<Uint8List> outputBytes,
  ) {
    if (rawOutputs is! List) {
      throw const FormatException('build_result outputs must be a list');
    }
    return <JsonMap>[
      for (final rawOutput in rawOutputs)
        _binaryOutputDescriptor(
          _asJsonMap(rawOutput, 'build output'),
          outputBytes,
        ),
    ];
  }

  JsonMap _binaryOutputDescriptor(JsonMap output, List<Uint8List> outputBytes) {
    final asset = output['asset'];
    final rawBytes = output['bytes'];
    if (asset is! String || rawBytes is! List) {
      throw const FormatException(
        'build output must contain an asset and bytes list',
      );
    }
    final bytes = rawBytes is Uint8List
        ? rawBytes
        : Uint8List.fromList(List<int>.from(rawBytes));
    outputBytes.add(bytes);
    return <String, dynamic>{'asset': asset, 'length': bytes.length};
  }

  JsonMap _asJsonMap(dynamic value, String label) {
    if (value is! Map) {
      throw FormatException('$label must be an object');
    }
    return value.cast<String, dynamic>();
  }

  /// Encodes one raw-byte frame and queues all of its chunks as one write.
  Future<void> _sendBinary(
    List<int> magic,
    JsonMap metadata,
    List<Uint8List> rawChunks,
  ) async {
    final metadataPayload = Uint8List.fromList(
      utf8.encode(jsonEncode(metadata)),
    );
    var rawLength = 0;
    for (final chunk in rawChunks) {
      rawLength += chunk.length;
    }
    final payloadLength = magic.length + 4 + metadataPayload.length + rawLength;
    if (payloadLength > _maxBuildResultFrameLength) {
      await _sendSplitBatch(metadata, rawChunks);
      return;
    }
    final header = ByteData(4)..setUint32(0, payloadLength, Endian.big);
    final metadataLength = ByteData(4)
      ..setUint32(0, metadataPayload.length, Endian.big);
    await _sendChunks([
      header.buffer.asUint8List(),
      magic,
      metadataLength.buffer.asUint8List(),
      metadataPayload,
      ...rawChunks,
    ]);
  }

  /// Keeps a whole frame and its flush exclusive on the shared IOSink.
  Future<void> _sendChunks(List<List<int>> chunks) {
    final sent = _pending.then((_) async {
      for (final chunk in chunks) {
        _output.add(chunk);
      }
      await _output.flush();
    });
    // Each caller observes its own failure; the queue must not introduce an
    // unhandled second error or block later diagnostic/error frames.
    _pending = sent.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return sent;
  }
}

class RpcSession {
  RpcSession(
    this.reader,
    this.writer, {
    required this.buildId,
    required this.phase,
    required this.postProcess,
    this.onControlMessage,
  });

  final FrameReader reader;
  final FrameWriter writer;
  final int buildId;
  final int phase;
  final bool postProcess;
  final RpcControlMessageHandler? onControlMessage;
  int _nextId = 1000;
  Future<void> _pending = Future<void>.value();

  /// Serializes round trips within this action, including nested demand.
  /// Nested actions own another session, so they can use the shared transport
  /// while this session is suspended in its control-message handler.
  Future<JsonMap> call(String op, Map<String, dynamic> parameters) {
    final id = _nextId++;
    final request = <String, dynamic>{
      'v': 1,
      'type': 'asset_request',
      'id': id,
      'op': op,
      ...parameters,
      'build_id': buildId,
      // Rust applies the same phase-aware logical view as the Dart adapter.
      // Each asset request carries the context Rust needs to enforce
      // visibility independently of the worker-side blocked_assets hint.
      'phase': phase,
      'kind': postProcess ? 'post_process' : 'normal',
    };
    final result = _pending.then((_) => _call(request, id));
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Owns the frame reader until this request and any nested actions complete.
  Future<JsonMap> _call(JsonMap request, int id) async {
    await writer.send(request);
    while (true) {
      final response = await reader.next();
      if (response == null) {
        throw const FormatException('Rust frontend exited during RPC');
      }
      validateProtocolVersion(response);
      if (response['type'] == 'build') {
        final handler = onControlMessage;
        if (handler == null) {
          throw StateError('Unexpected nested build request during asset RPC');
        }
        await handler(_decodeBuildRequest(response));
        continue;
      }
      if (response['type'] != 'asset_response' || response['id'] != id) {
        throw StateError(
          'Unexpected message while waiting for asset RPC: $response',
        );
      }
      if (response['ok'] != true) {
        throw StateError(response['error']?.toString() ?? 'Asset RPC failed');
      }
      return response;
    }
  }
}
