import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  static WorkerMessage decode(JsonMap message) {
    switch (message['type']) {
      case 'initialize':
        return WorkerInitializeMessage.fromJson(message);
      case 'reset':
        return WorkerResetMessage.fromJson(message);
      case 'reset_resolver':
        return WorkerResetResolverMessage.fromJson(message);
      case 'build':
        return WorkerBuildMessage(WorkerBuildRequest.fromJson(message));
      case 'build_batch':
        return WorkerBuildBatchMessage.fromJson(message);
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
    required this.phaseCount,
  }) : super(id: id);

  factory WorkerInitializeMessage.fromJson(JsonMap message) {
    final rawPhaseCount = message['phase_count'];
    final phaseCount = rawPhaseCount is num
        ? (rawPhaseCount.toInt() < 1 ? 1 : rawPhaseCount.toInt())
        : 1;
    final package = _requiredString(message, 'package', 'initialize');
    if (package.isEmpty) {
      throw const FormatException('initialize requires a non-empty package');
    }
    return WorkerInitializeMessage(
      id: _requiredInt(message, 'id', 'initialize'),
      package: package,
      phaseCount: phaseCount,
    );
  }

  final String package;
  final int phaseCount;
}

class WorkerResetMessage extends WorkerMessage {
  WorkerResetMessage({required int id}) : super(id: id);

  factory WorkerResetMessage.fromJson(JsonMap message) =>
      WorkerResetMessage(id: _requiredInt(message, 'id', 'reset'));
}

class WorkerResetResolverMessage extends WorkerMessage {
  WorkerResetResolverMessage({required int id}) : super(id: id);

  factory WorkerResetResolverMessage.fromJson(JsonMap message) =>
      WorkerResetResolverMessage(
        id: _requiredInt(message, 'id', 'reset_resolver'),
      );
}

class WorkerBuildMessage extends WorkerMessage {
  WorkerBuildMessage(this.request) : super(id: request.id);

  final WorkerBuildRequest request;
}

class WorkerBuildBatchMessage extends WorkerMessage {
  WorkerBuildBatchMessage({required int id, required this.requests})
    : super(id: id);

  factory WorkerBuildBatchMessage.fromJson(JsonMap message) {
    final rawRequests = message['requests'];
    if (rawRequests is! List) {
      throw const FormatException('build_batch requests must be a list');
    }
    return WorkerBuildBatchMessage(
      id: _requiredInt(message, 'id', 'build_batch'),
      requests: [
        for (final rawRequest in rawRequests)
          WorkerBuildRequest.fromJson(
            _jsonMap(rawRequest, 'build_batch request'),
          ),
      ],
    );
  }

  final List<WorkerBuildRequest> requests;
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
  });

  factory WorkerBuildRequest.fromJson(JsonMap message) {
    final rawKind = message['kind'];
    final kind = rawKind == null
        ? null
        : _requiredStringValue(rawKind, 'build kind');
    if (kind != null && kind != 'normal' && kind != 'post_process') {
      throw FormatException('unsupported build kind: $kind');
    }
    final rawIsRoot = message['is_root'];
    final rawInstanceKey = message['instance_key'];
    final rawPhase = message['phase'];
    final rawOptions = message['options'];
    final options = rawOptions == null
        ? <String, dynamic>{}
        : _stringKeyedMap(rawOptions, 'build options');
    final rawAllowedOutputs = message['allowed_outputs'];
    final rawBlockedAssets = message['blocked_assets'];
    final rawTriggers = message['triggers'];
    return WorkerBuildRequest(
      id: _requiredInt(message, 'id', 'build'),
      builder: _requiredString(message, 'builder', 'build'),
      input: _requiredString(message, 'input', 'build'),
      kind: kind,
      allowedOutputs: _stringList(
        rawAllowedOutputs ?? const <dynamic>[],
        'build allowed_outputs',
      ),
      options: options,
      phase: rawPhase is num ? rawPhase.toInt() : 0,
      instanceKey: rawInstanceKey is String && rawInstanceKey.isNotEmpty
          ? rawInstanceKey
          : null,
      isRoot: rawIsRoot is bool ? rawIsRoot : true,
      blockedAssets: _stringList(
        rawBlockedAssets ?? const <dynamic>[],
        'build blocked_assets',
      ),
      triggers: _triggerList(
        rawTriggers ?? const <dynamic>[],
        'build triggers',
      ),
    );
  }

  final int id;
  final String builder;
  final String input;
  final String? kind;
  final List<String> allowedOutputs;
  final Map<String, dynamic> options;
  final int phase;
  final String? instanceKey;
  final bool isRoot;
  final List<String> blockedAssets;
  final List<WorkerBuildTrigger> triggers;

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

int _requiredInt(JsonMap message, String key, String type) {
  final value = message[key];
  if (value is! int) {
    throw FormatException('$type requires an integer $key');
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

List<WorkerBuildTrigger> _triggerList(Object? value, String label) {
  if (value is! List) {
    throw FormatException('$label must be a list');
  }
  return [for (final item in value) WorkerBuildTrigger.fromJson(item)];
}

class FrameReader {
  FrameReader(Stream<List<int>> input) : _iterator = StreamIterator(input);

  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = <int>[];

  Future<JsonMap?> next() async {
    await _fill(4);
    if (_buffer.isEmpty) return null;

    final length = ByteData.sublistView(
      Uint8List.fromList(_buffer.sublist(0, 4)),
    ).getUint32(0, Endian.big);
    if (length > _maxFrameLength) {
      throw const FormatException('IPC frame exceeds the 256 MiB safety limit');
    }
    await _fill(4 + length);
    final payload = Uint8List.fromList(_buffer.sublist(4, 4 + length));
    _buffer.removeRange(0, 4 + length);
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
      utf8.decode(payload.sublist(envelopeHeaderLength, bytesStart)),
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
    while (_buffer.length < length) {
      if (!await _iterator.moveNext()) {
        if (_buffer.isEmpty) return;
        throw const FormatException('Unexpected EOF in IPC frame');
      }
      _buffer.addAll(_iterator.current);
    }
  }
}

class FrameWriter {
  FrameWriter(this._output);

  final IOSink _output;

  Future<void> send(JsonMap message) async {
    final payload = utf8.encode(jsonEncode(message));
    if (payload.length > _maxFrameLength) {
      throw StateError('IPC frame exceeds the 256 MiB safety limit');
    }
    final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
    _output.add(header.buffer.asUint8List());
    _output.add(payload);
    await _output.flush();
  }

  Future<void> sendBuildResult(JsonMap message) async {
    final outputBytes = <Uint8List>[];
    final metadata = _binaryBuildResultMetadata(message, outputBytes);
    await _sendBinary(_binaryBuildResultMagic, metadata, outputBytes);
  }

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
    if (payloadLength > _maxFrameLength) {
      throw StateError('IPC frame exceeds the 256 MiB safety limit');
    }
    final header = ByteData(4)..setUint32(0, payloadLength, Endian.big);
    final metadataLength = ByteData(4)
      ..setUint32(0, metadataPayload.length, Endian.big);
    _output.add(header.buffer.asUint8List());
    _output.add(magic);
    _output.add(metadataLength.buffer.asUint8List());
    _output.add(metadataPayload);
    for (final chunk in rawChunks) {
      _output.add(chunk);
    }
    await _output.flush();
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

  Future<JsonMap> call(String op, Map<String, dynamic> parameters) async {
    final id = _nextId++;
    await writer.send(<String, dynamic>{
      'v': 1,
      'type': 'asset_request',
      'id': id,
      'op': op,
      ...parameters,
      'build_id': buildId,
      // Rust applies the same phase-aware logical view as the Dart adapter.
      // Keeping these on every asset request also protects custom workers
      // which do not consume the build request's blocked_assets hint.
      'phase': phase,
      'kind': postProcess ? 'post_process' : 'normal',
    });
    while (true) {
      final response = await reader.next();
      if (response == null) {
        throw const FormatException('Rust frontend exited during RPC');
      }
      if (response['type'] == 'build') {
        final handler = onControlMessage;
        if (handler == null) {
          throw StateError('Unexpected nested build request during asset RPC');
        }
        await handler(WorkerBuildRequest.fromJson(response));
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
