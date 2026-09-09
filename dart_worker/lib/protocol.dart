import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef JsonMap = Map<String, dynamic>;

const List<int> _binaryAssetResponseMagic = <int>[0x46, 0x42, 0x52, 0x42];
const List<int> _binaryBuildResultMagic = <int>[0x46, 0x42, 0x52, 0x52];
const int _maxFrameLength = 256 * 1024 * 1024;

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
  RpcSession(this.reader, this.writer);

  final FrameReader reader;
  final FrameWriter writer;
  int _nextId = 1000;

  Future<JsonMap> call(String op, Map<String, dynamic> parameters) async {
    final id = _nextId++;
    await writer.send(<String, dynamic>{
      'v': 1,
      'type': 'asset_request',
      'id': id,
      'op': op,
      ...parameters,
    });
    while (true) {
      final response = await reader.next();
      if (response == null) {
        throw const FormatException('Rust frontend exited during RPC');
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
