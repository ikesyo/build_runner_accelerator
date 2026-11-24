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
  static const _maxRetainedCapacity = 8 * 1024;
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
    final buffer = _buffer;
    final payloadStart = _start + _headerLength;
    final payloadEnd = _start + frameLength;
    _start = payloadEnd;
    if (_start == _end) {
      if (buffer.length > _maxRetainedCapacity) _buffer = _emptyBuffer;
      _start = _end = 0;
    }
    if (_hasBinaryAssetResponseMagic(buffer, payloadStart, payloadEnd)) {
      // Binary bytes outlive the receive buffer and need an owned snapshot.
      return _decodeBinaryAssetResponse(
        buffer.sublist(payloadStart, payloadEnd),
      );
    }
    final decoded = jsonDecode(
      utf8.decoder.convert(buffer, payloadStart, payloadEnd),
    );
    if (decoded is! Map) {
      throw FormatException('IPC payload must be a JSON object');
    }
    return decoded.cast<String, dynamic>();
  }

  bool _hasBinaryAssetResponseMagic(Uint8List buffer, int start, int end) {
    if (end - start < _binaryAssetResponseMagic.length) return false;
    for (var index = 0; index < _binaryAssetResponseMagic.length; index++) {
      if (buffer[start + index] != _binaryAssetResponseMagic[index])
        return false;
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
