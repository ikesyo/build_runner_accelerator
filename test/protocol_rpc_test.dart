import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('skips empty chunks before and between complete frames', () async {
    final reader = FrameReader(
      Stream.fromIterable([
        <int>[],
        Uint8List.fromList(_frame(utf8.encode('{"id":1}'))),
        Uint8List(0),
        Uint8List.fromList(_frame(utf8.encode('{"id":2}'))),
        <int>[],
      ]),
    );

    expect(await reader.next(), {'id': 1});
    expect(await reader.next(), {'id': 2});
    expect(await reader.next(), isNull);
  });

  test('reads mixed frames at every split and one byte at a time', () async {
    final bytes = [
      ..._frame(utf8.encode('{"type":"first"}')),
      ..._assetFrame([0, 255, 1]),
      ..._frame(utf8.encode('{"type":"last"}')),
    ];
    final partitions = [
      for (var split = 0; split <= bytes.length; split++)
        [
          Uint8List.fromList(bytes.sublist(0, split)),
          <int>[],
          bytes.sublist(split),
        ],
      [
        for (final byte in bytes) [byte],
      ],
    ];
    for (final chunks in partitions) {
      final reader = FrameReader(Stream.fromIterable(chunks));
      expect(await reader.next(), {'type': 'first'});
      final binary = (await reader.next())!;
      expect(await reader.next(), {'type': 'last'});
      expect(binary['bytes'], [0, 255, 1]);
      expect(await reader.next(), isNull);
    }
  });

  test('retains unread bytes and returned assets across compaction', () async {
    final asset = List.generate(128, (index) => index);
    final nextFrame = _frame(utf8.encode('{"type":"next"}'));
    final firstChunk = Uint8List.fromList([
      ..._assetFrame(asset),
      ...nextFrame.take(2),
    ]);
    final reader = FrameReader(
      Stream.fromIterable([firstChunk, nextFrame.sublist(2)]),
    );

    final binary = (await reader.next())!;
    firstChunk.fillRange(0, firstChunk.length, 0xff);
    expect(await reader.next(), {'type': 'next'});
    expect(binary['bytes'], asset);
    expect(await reader.next(), isNull);
  });

  test('returned assets survive reuse of a drained receive buffer', () async {
    final asset = List.generate(128, (index) => index);
    final next = {'type': 'next', 'value': 'é' * 70};
    final reader = FrameReader(
      Stream.fromIterable([
        _assetFrame(asset),
        _frame(utf8.encode(jsonEncode(next))),
      ]),
    );

    final binary = (await reader.next())!;
    expect(await reader.next(), next);
    expect(binary['bytes'], asset);
  });

  test('preserves unread bytes during overlapping compaction', () async {
    final first = _frame(utf8.encode('{"id":1}'));
    final secondMessage = {'id': 2, 'text': '日本語' * 8};
    final second = _frame(utf8.encode(jsonEncode(secondMessage)));
    final split = second.length - 4;
    final reader = FrameReader(
      Stream.fromIterable([
        Uint8List.fromList([...first, ...second.take(split)]),
        Uint8List.fromList(second.sublist(split)),
      ]),
    );

    expect(await reader.next(), {'id': 1});
    expect(await reader.next(), secondMessage);
    expect(await reader.next(), isNull);
  });

  test('owns only the raw bytes of a large fragmented asset', () async {
    final asset = Uint8List(70 * 1024)..last = 0xff;
    final frame = Uint8List.fromList(_assetFrame(asset));
    final reader = FrameReader(
      Stream.fromIterable([
        Uint8List.sublistView(frame, 0, 32 * 1024),
        Uint8List.sublistView(frame, 32 * 1024),
        _frame(utf8.encode('{"id":2}')),
        _frame(utf8.encode('{"id":3}')),
      ]),
    );

    final bytes = (await reader.next())!['bytes'] as Uint8List;
    frame.fillRange(0, frame.length, 0);
    expect(await reader.next(), {'id': 2});
    expect(await reader.next(), {'id': 3});
    expect(bytes.buffer.lengthInBytes, asset.length);
    expect(bytes, asset);
    expect(await reader.next(), isNull);
  });

  test('preserves BOM and error handling for JSON payloads', () async {
    final message = {'type': 'next', 'text': 'é 🐈 日本語'};
    const bom = [0xef, 0xbb, 0xbf];
    final invalidJson = [...utf8.encode('{"text":"'), 0xff, 0x22, 0x7d];
    const invalidSyntax = '{"text":}';
    final reader = FrameReader(
      Stream.value(
        Uint8List.fromList([
          ..._frame([...bom, ...utf8.encode(jsonEncode(message))]),
          ..._frame(invalidJson),
          ..._frame([...ascii.encode('BRAB'), ..._frame(invalidJson)]),
          ..._frame(utf8.encode(invalidSyntax)),
          ..._frame(utf8.encode(jsonEncode(message))),
        ]),
      ),
    );

    expect(await reader.next(), message);
    await expectLater(reader.next(), throwsFormatException);
    await expectLater(reader.next(), throwsFormatException);
    await expectLater(
      reader.next(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.source,
          'source',
          invalidSyntax,
        ),
      ),
    );
    expect(await reader.next(), message);
    expect(await reader.next(), isNull);
  });

  test(
    'format errors keep only their own payload after buffer reuse',
    () async {
      const invalidSyntax = '{"a":}';
      final invalidUtf8 = [...ascii.encode('{"a":"'), 0xff, 0x22, 0x7d];
      for (final (payload, source, offset) in [
        (utf8.encode(invalidSyntax), invalidSyntax, 5),
        (invalidUtf8, invalidUtf8, 6),
      ]) {
        final reader = FrameReader(
          Stream.fromIterable([
            Uint8List.fromList([
              ..._frame(utf8.encode('{"id":1}')),
              ..._frame(payload),
            ]),
            _frame(utf8.encode('{"id":2000000000}')),
          ]),
        );

        expect(await reader.next(), {'id': 1});
        final FormatException error;
        try {
          await reader.next();
          fail('Expected the malformed payload to throw');
        } on FormatException catch (caught) {
          error = caught;
        }
        expect(error.source, source);
        expect(error.offset, offset);
        expect(await reader.next(), {'id': 2000000000});
        expect(error.source, source);
      }
    },
  );

  test('distinguishes a clean EOF from invalid frame boundaries', () async {
    expect(await FrameReader(Stream.value(<int>[])).next(), isNull);
    final frame = _frame(utf8.encode('{"type":"message"}'));
    for (var end = 1; end < frame.length; end++) {
      final reader = FrameReader(Stream.value(frame.sublist(0, end)));
      await expectLater(reader.next(), throwsFormatException);
    }
    final truncated = FrameReader(Stream.value([0x10, 0, 0, 0, 0]));
    await expectLater(
      truncated.next(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Unexpected EOF in IPC frame',
        ),
      ),
    );
    final oversizedChunk = [0x10, 0, 0, 1, ...frame];
    for (final chunk in [oversizedChunk, Uint8List.fromList(oversizedChunk)]) {
      final oversized = FrameReader(Stream.value(chunk));
      // A framing error must not consume the header or the following bytes.
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          oversized.next(),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'IPC frame exceeds the 256 MiB safety limit',
            ),
          ),
        );
      }
    }
  });

  test('a malformed payload consumes only its own frame', () async {
    final reader = FrameReader(
      Stream.value([
        ..._frame([0xff]),
        ..._frame(utf8.encode('{"type":"next"}')),
      ]),
    );
    await expectLater(reader.next(), throwsFormatException);
    expect(await reader.next(), {'type': 'next'});
    expect(await reader.next(), isNull);
  });

  test(
    'concurrent JSON and binary frames retain order and complete bytes',
    () async {
      final stream = StreamController<List<int>>();
      final output = IOSink(stream.sink);
      final writer = FrameWriter(output);
      final collected = stream.stream.expand((chunk) => chunk).toList();
      await Future.wait([
        writer.send({'v': 1, 'type': 'first'}),
        writer.sendBuildResult({
          'v': 1,
          'type': 'build_result',
          'id': 1,
          'outputs': [
            {
              'asset': 'app|lib/a.bin',
              'bytes': Uint8List.fromList([0, 255, 1]),
            },
          ],
        }),
        writer.send({'v': 1, 'type': 'last'}),
      ]);
      await output.close();
      final bytes = Uint8List.fromList(await collected);
      var offset = 0;
      Uint8List next() {
        final length = ByteData.sublistView(
          bytes,
          offset,
          offset + 4,
        ).getUint32(0);
        offset += 4;
        final result = Uint8List.sublistView(bytes, offset, offset + length);
        offset += length;
        return result;
      }

      expect(jsonDecode(utf8.decode(next()))['type'], 'first');
      final binary = next();
      expect(utf8.decode(binary.sublist(0, 4)), 'BRAR');
      final metadataLength = ByteData.sublistView(binary, 4, 8).getUint32(0);
      final metadata = jsonDecode(
        utf8.decode(binary.sublist(8, 8 + metadataLength)),
      );
      expect(metadata['outputs'], [
        {'asset': 'app|lib/a.bin', 'length': 3},
      ]);
      expect(binary.sublist(8 + metadataLength), [0, 255, 1]);
      expect(jsonDecode(utf8.decode(next()))['type'], 'last');
      expect(offset, bytes.length);
    },
  );

  test(
    'parallel RPC calls retain nested session ownership and recover after an API error',
    () async {
      final requests = StreamController<List<int>>();
      final responses = StreamController<List<int>>();
      // Model OS pipe buffers: IOSink(controller.sink).flush() pauses addStream
      // when StreamIterator pauses between frames, which can deadlock in-memory
      // peers when a complete frame arrives in one chunk before the peer reads.
      final output = IOSink(_PipeSink(requests));
      final peerOutput = IOSink(_PipeSink(responses));
      final writer = FrameWriter(output);
      final reader = FrameReader(responses.stream);
      final peerReader = FrameReader(requests.stream);
      final peerWriter = FrameWriter(peerOutput);
      final trace = <String>[];
      final nested = RpcSession(
        reader,
        writer,
        buildId: 2,
        phase: 1,
        postProcess: false,
      );
      final outer = RpcSession(
        reader,
        writer,
        buildId: 1,
        phase: 2,
        postProcess: false,
        onControlMessage: (request) async {
          expect(request.id, 2);
          await Future.wait([
            nested.call('read', {'asset': 'nested-a'}),
            nested.call('read', {'asset': 'nested-b'}),
          ]);
        },
      );
      final peer = () async {
        final first = (await peerReader.next())!;
        trace.add(first['asset'] as String);
        await peerWriter.send({
          'v': 1,
          'type': 'build',
          'id': 2,
          'builder': 'app:optional',
          'input': 'app|lib/a.dart',
          'kind': 'normal',
          'phase': 1,
          'instance_key': 'optional',
          'is_root': true,
          'blocked_assets': <String>[],
          'allowed_outputs': <String>[],
          'options': <String, Object?>{},
          'triggers': <Object?>[],
        });
        for (final asset in ['nested-a', 'nested-b']) {
          final request = (await peerReader.next())!;
          expect(request['asset'], asset);
          expect(request['build_id'], 2);
          trace.add(asset);
          await peerWriter.send({
            'v': 1,
            'type': 'asset_response',
            'id': request['id'],
            'ok': true,
          });
        }
        await peerWriter.send({
          'v': 1,
          'type': 'asset_response',
          'id': first['id'],
          'ok': false,
          'error': 'missing',
        });
        final last = (await peerReader.next())!;
        expect(last['build_id'], 1);
        trace.add(last['asset'] as String);
        await peerWriter.send({
          'v': 1,
          'type': 'asset_response',
          'id': last['id'],
          'ok': true,
          'value': true,
        });
      }();
      final failed = expectLater(
        outer.call('read', {'asset': 'outer-a'}),
        throwsStateError,
      );
      final success = outer.call('can_read', {'asset': 'outer-b'});
      await Future.wait([
        peer,
        failed,
        success,
      ]).timeout(const Duration(seconds: 5));
      expect((await success)['value'], isTrue);
      expect(trace, ['outer-a', 'nested-a', 'nested-b', 'outer-b']);
      final closing = [output.close(), peerOutput.close()];
      expect(await peerReader.next(), isNull);
      expect(await reader.next(), isNull);
      await Future.wait(closing);
    },
  );

  test(
    'FrameWriter coalesces small frames and preserves large UTF-8 and binary frames',
    () async {
      final sink = _RecordingSink();
      final writer = FrameWriter(sink);

      final smallJson = {'v': 1, 'type': 'ping', 'text': 'é 🐈 日本語'};
      await writer.send(smallJson);
      expect(sink.chunks, hasLength(1));

      final largeJson = {'v': 1, 'type': 'big', 'text': 'あ' * 4000};
      final beforeLargeJson = sink.chunks.length;
      await writer.send(largeJson);
      expect(sink.chunks.length - beforeLargeJson, 2);

      final smallBinary = Uint8List.fromList([0, 127, 255]);
      final beforeSmallBinary = sink.chunks.length;
      await writer.sendBuildResult({
        'v': 1,
        'type': 'build_result',
        'id': 1,
        'outputs': [
          {'asset': 'app|lib/small.bin', 'bytes': smallBinary},
        ],
      });
      expect(sink.chunks.length - beforeSmallBinary, 1);

      final largeBinary = Uint8List.fromList(
        List.generate(10 * 1024, (i) => i % 256),
      );
      final beforeLargeBinary = sink.chunks.length;
      await writer.sendBuildResult({
        'v': 1,
        'type': 'build_result',
        'id': 2,
        'outputs': [
          {'asset': 'app|lib/large.bin', 'bytes': largeBinary},
        ],
      });
      // 12-byte combined header + metadata payload + raw output chunk.
      expect(sink.chunks.length - beforeLargeBinary, 3);
      expect(sink.chunks[beforeLargeBinary], hasLength(12));

      final reader = FrameReader(
        Stream.fromIterable(sink.chunks.sublist(0, beforeSmallBinary)),
      );
      expect(await reader.next(), smallJson);
      expect(await reader.next(), largeJson);
      expect(await reader.next(), isNull);

      final binaryBytes = Uint8List.fromList(
        sink.chunks
            .sublist(beforeSmallBinary)
            .expand((chunk) => chunk)
            .toList(),
      );
      var offset = 0;
      for (final (expectedId, expectedAsset, expectedBytes) in [
        (1, 'app|lib/small.bin', smallBinary),
        (2, 'app|lib/large.bin', largeBinary),
      ]) {
        final frameLength = ByteData.sublistView(
          binaryBytes,
          offset,
          offset + 4,
        ).getUint32(0);
        offset += 4;
        expect(ascii.decode(binaryBytes.sublist(offset, offset + 4)), 'BRAR');
        final metadataLength = ByteData.sublistView(
          binaryBytes,
          offset + 4,
          offset + 8,
        ).getUint32(0);
        final metadata =
            jsonDecode(
                  utf8.decode(
                    binaryBytes.sublist(
                      offset + 8,
                      offset + 8 + metadataLength,
                    ),
                  ),
                )
                as Map<String, dynamic>;
        expect(metadata['id'], expectedId);
        expect(metadata['outputs'], [
          {'asset': expectedAsset, 'length': expectedBytes.length},
        ]);
        expect(
          binaryBytes.sublist(
            offset + 8 + metadataLength,
            offset + frameLength,
          ),
          expectedBytes,
        );
        offset += frameLength;
      }
      expect(offset, binaryBytes.length);
    },
  );
}

class _PipeSink implements StreamConsumer<List<int>> {
  _PipeSink(this._controller);

  final StreamController<List<int>> _controller;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _controller.add(chunk);
    }
  }

  @override
  Future<void> close() => _controller.close();
}

class _RecordingSink implements IOSink {
  final chunks = <Uint8List>[];

  @override
  void add(List<int> data) {
    chunks.add(Uint8List.fromList(data));
  }

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('$invocation');
}

List<int> _frame(List<int> payload) {
  final length = ByteData(4)..setUint32(0, payload.length);
  return [...length.buffer.asUint8List(), ...payload];
}

List<int> _assetFrame(List<int> bytes) => _frame([
  ...ascii.encode('BRAB'),
  ..._frame(
    utf8.encode(
      jsonEncode({
        'type': 'asset_response',
        'encoding': 'raw',
        'length': bytes.length,
      }),
    ),
  ),
  ...bytes,
]);
