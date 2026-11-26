import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'protocol_messages.dart' show JsonMap;

const List<int> _binaryAssetResponseMagic = <int>[0x42, 0x52, 0x41, 0x42];
const List<int> _binaryBuildResultMagic = <int>[0x42, 0x52, 0x41, 0x52];
const int _maxFrameLength = 256 * 1024 * 1024;

class FrameReader {
  FrameReader(Stream<List<int>> input) : _iterator = StreamIterator(input);

  static final _emptyBuffer = Uint8List(0);
  static final _jsonDecoder = utf8.decoder.fuse(json.decoder);
  static const _maxRetainedCapacity = 64 * 1024;
  static const _headerLength = 4;
  final StreamIterator<List<int>> _iterator;
  Uint8List _buffer = _emptyBuffer;
  int _start = 0;
  int _end = 0;

  int get _available => _end - _start;

  Future<JsonMap?> next() async {
    if (_available == 0) {
      if (!await _iterator.moveNext()) return null;
      final chunk = _iterator.current;
      if (chunk is Uint8List && chunk.length >= _headerLength) {
        final length = _readUint32(chunk, 0);
        if (length <= _maxFrameLength &&
            chunk.length == _headerLength + length) {
          // Decode synchronously while the input chunk belongs to this read.
          return _decodePayload(chunk, _headerLength, chunk.length);
        }
      }
      _append(chunk, _headerLength);
    }
    if (_available < _headerLength) await _fill(_headerLength);
    if (_available == 0) return null;

    final length = _readUint32(_buffer, _start);
    if (length > _maxFrameLength) {
      throw const FormatException('IPC frame exceeds the 256 MiB safety limit');
    }
    final frameLength = _headerLength + length;
    if (_available < frameLength) await _fill(frameLength);
    final buffer = _buffer;
    final payloadStart = _start + _headerLength;
    final payloadEnd = _start + frameLength;
    _start = payloadEnd;
    if (_start == _end) {
      if (buffer.length > _maxRetainedCapacity) _buffer = _emptyBuffer;
      _start = _end = 0;
    }
    return _decodePayload(buffer, payloadStart, payloadEnd);
  }

  JsonMap _decodePayload(Uint8List buffer, int start, int end) {
    if (_hasBinaryAssetResponseMagic(buffer, start, end)) {
      return _decodeBinaryAssetResponse(buffer, start, end);
    }
    final decoded = _decodeJson(buffer, start, end);
    if (decoded is! JsonMap) {
      throw FormatException('IPC payload must be a JSON object');
    }
    return decoded;
  }

  Object? _decodeJson(Uint8List buffer, int start, int end) {
    try {
      return _jsonDecoder.convert(Uint8List.sublistView(buffer, start, end));
    } on FormatException {
      // Preserve the decoder's diagnostics without exposing the input buffer.
      return jsonDecode(utf8.decode(buffer.sublist(start, end)));
    }
  }

  static int _readUint32(Uint8List buffer, int offset) =>
      (buffer[offset] << 24) |
      (buffer[offset + 1] << 16) |
      (buffer[offset + 2] << 8) |
      buffer[offset + 3];

  bool _hasBinaryAssetResponseMagic(Uint8List buffer, int start, int end) {
    if (end - start < _binaryAssetResponseMagic.length) return false;
    for (var index = 0; index < _binaryAssetResponseMagic.length; index++) {
      if (buffer[start + index] != _binaryAssetResponseMagic[index])
        return false;
    }
    return true;
  }

  JsonMap _decodeBinaryAssetResponse(Uint8List buffer, int start, int end) {
    const envelopeHeaderLength = 8;
    if (end - start < envelopeHeaderLength) {
      throw const FormatException('Binary IPC envelope is truncated');
    }
    final metadataLength = _readUint32(
      buffer,
      start + _binaryAssetResponseMagic.length,
    );
    final metadataStart = start + envelopeHeaderLength;
    final bytesStart = metadataStart + metadataLength;
    if (bytesStart > end) {
      throw const FormatException('Binary IPC metadata is truncated');
    }

    final message = _decodeJson(buffer, metadataStart, bytesStart);
    if (message is! JsonMap) {
      throw const FormatException('Binary IPC metadata must be a JSON object');
    }
    if (message['type'] != 'asset_response' || message['encoding'] != 'raw') {
      throw const FormatException('Unsupported binary IPC envelope');
    }
    final expectedLength = message['length'];
    final actualLength = end - bytesStart;
    if (expectedLength is! int || expectedLength != actualLength) {
      throw const FormatException('Binary IPC payload length mismatch');
    }
    // Asset bytes can outlive the receive buffer.
    message['bytes'] = buffer.sublist(bytesStart, end);
    return message;
  }

  Future<void> _fill(int length) async {
    while (_available < length) {
      if (!await _iterator.moveNext()) {
        if (_available == 0) return;
        throw const FormatException('Unexpected EOF in IPC frame');
      }
      _append(_iterator.current, length);
    }
  }

  void _append(List<int> chunk, int frameLength) {
    final chunkLength = chunk.length;
    if (chunkLength == 0) return;
    if (_end + chunkLength > _buffer.length) {
      final available = _available;
      final required = available + chunkLength;
      var buffer = _buffer;
      if (required > buffer.length) {
        // Reserve the rest of a known frame only once enough bytes arrived
        // to bound capacity by twice the bytes actually received.
        final capacity = required <= frameLength && frameLength <= required * 2
            ? frameLength
            : max(
                required,
                min(buffer.length * 2, _maxFrameLength + _headerLength),
              );
        buffer = Uint8List(capacity);
      }
      if (available > 0) buffer.setRange(0, available, _buffer, _start);
      _buffer = buffer;
      _start = 0;
      _end = available;
    }
    _buffer.setRange(_end, _end + chunkLength, chunk);
    _end += chunkLength;
  }
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

  static final _jsonEncoder = JsonUtf8Encoder();
  static const _maxCoalescedPayloadLength = 8 * 1024;
  final IOSink _output;
  final int _maxBuildResultFrameLength;
  Future<void> _pending = Future<void>.value();

  static Uint8List _encodeJson(JsonMap message) {
    final encoded = _jsonEncoder.convert(message);
    return encoded is Uint8List ? encoded : Uint8List.fromList(encoded);
  }

  static void _writeUint32(Uint8List buffer, int offset, int value) {
    buffer[offset] = (value >> 24) & 0xff;
    buffer[offset + 1] = (value >> 16) & 0xff;
    buffer[offset + 2] = (value >> 8) & 0xff;
    buffer[offset + 3] = value & 0xff;
  }

  /// Enqueues a JSON frame without interleaving it with another send's flush.
  Future<void> send(JsonMap message) async {
    final payload = _encodeJson(message);
    final payloadLength = payload.length;
    if (payloadLength > _maxFrameLength) {
      throw StateError('IPC frame exceeds the 256 MiB safety limit');
    }
    if (payloadLength <= _maxCoalescedPayloadLength) {
      final frame = Uint8List(4 + payloadLength);
      _writeUint32(frame, 0, payloadLength);
      frame.setRange(4, frame.length, payload);
      await _sendChunk(frame);
      return;
    }
    final header = Uint8List(4);
    _writeUint32(header, 0, payloadLength);
    await _sendChunks([header, payload]);
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
    final metadataPayload = _encodeJson(metadata);
    var rawLength = 0;
    for (final chunk in rawChunks) {
      rawLength += chunk.length;
    }
    final payloadLength = magic.length + 4 + metadataPayload.length + rawLength;
    if (payloadLength > _maxBuildResultFrameLength) {
      await _sendSplitBatch(metadata, rawChunks);
      return;
    }
    final headerLength = 4 + magic.length + 4;
    if (metadataPayload.length + rawLength <= _maxCoalescedPayloadLength) {
      final frame = Uint8List(
        headerLength + metadataPayload.length + rawLength,
      );
      _writeUint32(frame, 0, payloadLength);
      frame.setRange(4, 4 + magic.length, magic);
      _writeUint32(frame, 4 + magic.length, metadataPayload.length);
      var offset = headerLength;
      frame.setRange(offset, offset + metadataPayload.length, metadataPayload);
      offset += metadataPayload.length;
      for (final chunk in rawChunks) {
        frame.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      await _sendChunk(frame);
      return;
    }
    final header = Uint8List(headerLength);
    _writeUint32(header, 0, payloadLength);
    header.setRange(4, 4 + magic.length, magic);
    _writeUint32(header, 4 + magic.length, metadataPayload.length);
    await _sendChunks([header, metadataPayload, ...rawChunks]);
  }

  /// Keeps a single-chunk frame and its flush exclusive on the shared IOSink.
  Future<void> _sendChunk(Uint8List chunk) {
    final sent = _pending.then((_) async {
      _output.add(chunk);
      await _output.flush();
    });
    // Each caller observes its own failure; the queue must not introduce an
    // unhandled second error or block later diagnostic/error frames.
    _pending = sent.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return sent;
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
