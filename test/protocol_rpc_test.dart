import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:test/test.dart';

void main() {
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
    final oversized = FrameReader(Stream.value([0x10, 0, 0, 1, ...frame]));
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
      final output = IOSink(requests.sink);
      final peerOutput = IOSink(responses.sink);
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
