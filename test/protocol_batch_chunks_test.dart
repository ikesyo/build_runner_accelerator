import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:test/test.dart';

JsonMap result(int id, Uint8List bytes) => {
  'v': 1,
  'type': 'build_result',
  'id': id,
  'status': 'success',
  'execution_us': 5000,
  'outputs': [
    {'asset': 'app|$id.bin', 'bytes': bytes},
  ],
  'reads': <String>[],
  'deleted': <String>[],
  'resolver_reads': <String>[],
  'resolver_entrypoints': <String>[],
  'resolver_used': false,
  'glob_reads': <dynamic>[],
  'diagnostics': <dynamic>[],
};

JsonMap batch(List<JsonMap> results, [JsonMap? graph]) => {
  'v': 1,
  'type': 'build_batch_result',
  'id': 42,
  'results': results,
  'dep_graph': graph ?? <String, dynamic>{},
};

Future<List<(JsonMap, Uint8List)>> frames(JsonMap message, int limit) async {
  final stream = StreamController<List<int>>();
  final sink = IOSink(stream.sink);
  final bytesFuture = stream.stream.expand((bytes) => bytes).toList();
  await FrameWriter(
    sink,
    maxBuildResultFrameLength: limit,
  ).sendBuildResult(message);
  await sink.close();
  final bytes = Uint8List.fromList(await bytesFuture);
  final decoded = <(JsonMap, Uint8List)>[];
  var offset = 0;
  while (offset < bytes.length) {
    final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    expect(length, lessThanOrEqualTo(limit));
    offset += 4;
    expect(ascii.decode(bytes.sublist(offset, offset + 4)), 'BRAR');
    final metadataLength = ByteData.sublistView(
      bytes,
      offset + 4,
      offset + 8,
    ).getUint32(0);
    final rawStart = offset + 8 + metadataLength;
    decoded.add((
      (jsonDecode(utf8.decode(bytes.sublist(offset + 8, rawStart))) as Map)
          .cast<String, dynamic>(),
      Uint8List.sublistView(bytes, rawStart, offset + length),
    ));
    offset += length;
  }
  return decoded;
}

void main() {
  test(
    'ordinary batch keeps its single-frame schema and complete payload',
    () async {
      final decoded = await frames(
        batch([
          result(0, Uint8List.fromList([0, 255, 1])),
        ]),
        2048,
      );
      expect(decoded, hasLength(1));
      expect(decoded.single.$1['type'], 'build_batch_result');
      expect(decoded.single.$1.keys.toSet(), {
        'v',
        'type',
        'id',
        'results',
        'dep_graph',
        'encoding',
      });
      expect(decoded.single.$2, [0, 255, 1]);
    },
  );

  test(
    'oversized batch preserves all IDs, bytes, timing and graph once',
    () async {
      final bytes = Uint8List.fromList(List.generate(400, (i) => i % 256));
      final graph = {
        'app|entry.dart': ['app|dependency.dart'],
      };
      final decoded = await frames(
        batch([for (var i = 0; i < 9; i++) result(i, bytes)], graph),
        1800,
      );
      expect(decoded.length, greaterThan(1));
      expect(decoded.last.$1['type'], 'build_batch_result');
      expect(
        decoded
            .take(decoded.length - 1)
            .every((p) => p.$1['type'] == 'build_batch_chunk'),
        isTrue,
      );
      final ids = <int>[];
      final graphs = <String, dynamic>{};
      for (final (metadata, raw) in decoded) {
        expect(metadata['id'], 42);
        var consumed = 0;
        for (final item in metadata['results'] as List) {
          ids.add(item['id'] as int);
          expect(item['execution_us'], 5000);
          expect(raw.sublist(consumed, consumed + bytes.length), bytes);
          consumed += bytes.length;
        }
        expect(consumed, raw.length);
        for (final key in (metadata['dep_graph'] as Map).keys) {
          expect(graphs.containsKey(key), isFalse);
          graphs[key as String] = metadata['dep_graph'][key];
        }
      }
      expect(ids, List.generate(9, (i) => i));
      expect(graphs, graph);
    },
  );

  test('one result that fits exactly also fits a nonfinal frame', () async {
    final message = batch([result(0, Uint8List(300))]);
    final original = await frames(message, 2048);
    final limit = 8 + utf8.encode(jsonEncode(original.single.$1)).length + 300;
    final decoded = await frames(
      batch([result(0, Uint8List(300)), result(1, Uint8List(300))]),
      limit,
    );
    expect(decoded, hasLength(2));
    expect(decoded.first.$1['type'], 'build_batch_chunk');
    expect(decoded.last.$1['type'], 'build_batch_result');
  });

  test('split raw chunks follow mixed output counts and byte lists', () async {
    final first = result(0, Uint8List(0))..['outputs'] = <dynamic>[];
    final second = result(1, Uint8List.fromList(List.filled(400, 11)));
    (second['outputs'] as List).add({
      'asset': 'app|second.bin',
      'bytes': List.filled(400, 22),
    });
    final decoded = await frames(
      batch([
        first,
        second,
        result(2, Uint8List.fromList(List.filled(400, 33))),
      ]),
      1800,
    );
    expect(decoded.length, greaterThan(1));
    final bytes = decoded.expand((frame) => frame.$2).toList();
    expect(bytes, [
      ...List.filled(400, 11),
      ...List.filled(400, 22),
      ...List.filled(400, 33),
    ]);
    expect(
      decoded
          .expand((frame) => frame.$1['results'] as List)
          .map((r) => r['id']),
      [0, 1, 2],
    );
  });

  test(
    'dependency metadata is split without losing or duplicating entries',
    () async {
      final graph = {
        for (var i = 0; i < 20; i++)
          'app|entry_$i.dart': ['app|${'x' * 100}_$i.dart'],
      };
      final decoded = await frames(
        batch([result(0, Uint8List(500))], graph),
        1600,
      );
      expect(decoded.length, greaterThan(1));
      final merged = <String, dynamic>{};
      var resultCount = 0;
      for (final (metadata, _) in decoded) {
        resultCount += (metadata['results'] as List).length;
        for (final entry in (metadata['dep_graph'] as Map).entries) {
          expect(merged.containsKey(entry.key), isFalse);
          merged[entry.key as String] = entry.value;
        }
      }
      expect(resultCount, 1);
      expect(merged, graph);
      expect(decoded.last.$1['type'], 'build_batch_result');
    },
  );

  test('an individual oversized action is still refused', () async {
    final stream = StreamController<List<int>>();
    final sink = IOSink(stream.sink);
    final collected = stream.stream.expand((b) => b).toList();
    await expectLater(
      FrameWriter(
        sink,
        maxBuildResultFrameLength: 512,
      ).sendBuildResult(batch([result(0, Uint8List(1024))])),
      throwsStateError,
    );
    await sink.close();
    expect(await collected, isEmpty);
  });

  test(
    'the production 256 MiB limit splits 400 one-MiB outputs into two frames',
    () async {
      final sink = CountingSink();
      final bytes = Uint8List(1024 * 1024);
      await FrameWriter(sink).sendBuildResult(
        batch([for (var i = 0; i < 400; i++) result(i, bytes)]),
      );
      expect(sink.lengths, hasLength(2));
      expect(
        sink.lengths.every((length) => length <= 256 * 1024 * 1024),
        isTrue,
      );
      expect(sink.rawBytes, 400 * 1024 * 1024);
    },
  );
}

// Count the real production-boundary case without allocating 400 MiB of test
// buffers or copying output bytes. FrameWriter writes each framed chunk intact.
class CountingSink implements IOSink {
  final lengths = <int>[];
  int remaining = 0;
  int part = 0;
  int rawBytes = 0;

  @override
  void add(List<int> bytes) {
    if (remaining == 0) {
      final length = ByteData.sublistView(
        Uint8List.fromList(bytes),
      ).getUint32(0);
      lengths.add(length);
      remaining = length;
      part = 0;
    } else {
      if (part >= 3) rawBytes += bytes.length;
      remaining -= bytes.length;
      expect(remaining, greaterThanOrEqualTo(0));
      part++;
    }
  }

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('$invocation');
}
