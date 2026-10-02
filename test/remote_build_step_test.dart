import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:build_runner_accelerator/src/remote_build_step.dart';
import 'package:test/test.dart';

void main() {
  for (final error in [
    'prefetch disabled during lazy builds',
    'resolve_assets response exceeds frame limit',
  ]) {
    test('declined prefetch ($error) preserves sequential reads', () async {
      final id = AssetId('app', 'lib/generated.dart');
      final cache = <AssetId, List<int>>{};
      final readable = <AssetId>{};
      final temporary = await Directory.systemTemp.createTemp(
        'prefetch-fallback-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/generated.dart');
      await file.writeAsBytes([1, 2, 3]);
      final responses = [
        {'id': 1000, 'ok': false, 'error': error},
        {'id': 1001, 'ok': true, 'value': true},
        {'id': 1002, 'ok': true, 'path': file.path},
      ];
      final frames = responses.map((response) {
        final payload = utf8.encode(
          jsonEncode({'v': 1, 'type': 'asset_response', ...response}),
        );
        final header = ByteData(4)..setUint32(0, payload.length);
        return [...header.buffer.asUint8List(), ...payload];
      });
      final sink = IOSink(_DiscardingConsumer());
      addTearDown(sink.close);
      final io = RemoteAssetReaderWriter(
        readCache: cache,
        readableCache: readable,
      );
      io.beginAction(
        rpc: RpcSession(
          FrameReader(Stream.fromIterable(frames)),
          FrameWriter(sink),
          buildId: 1,
          phase: 1,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: {},
      );
      await io.prefetchAssets([id]);
      expect(cache, isEmpty);
      expect(readable, isEmpty);
      expect(io.observedReads, isEmpty);
      expect(await io.canRead(id), isTrue);
      expect(await io.readAsBytes(id), [1, 2, 3]);
      expect(io.observedReads, {id});
      io.endAction();
    });
  }

  test('nested actions restore the outer asset IO context', () async {
    final outerInput = AssetId('app', 'lib/outer.dart');
    final outerOutput = AssetId('app', 'lib/outer.txt');
    final nestedInput = AssetId('app', 'lib/nested.dart');
    final nestedOutput = AssetId('app', 'lib/nested.txt');
    final outerBlocked = AssetId('app', 'lib/outer_blocked.dart');
    final nestedBlocked = AssetId('app', 'lib/nested_blocked.dart');
    final io = RemoteAssetReaderWriter(
      readCache: <AssetId, List<int>>{
        outerInput: <int>[1],
        nestedInput: <int>[2],
        outerBlocked: <int>[3],
        nestedBlocked: <int>[4],
      },
      readableCache: <AssetId>{},
    );
    final outerRpc = _rpc();
    final nestedRpc = _rpc();

    io.beginAction(
      rpc: outerRpc,
      package: 'app',
      primaryInput: outerInput,
      blockedAssets: {outerBlocked},
    );
    final outerOutputs = io.outputs;
    await io.writeAsString(outerOutput, 'outer');

    io.beginAction(
      rpc: nestedRpc,
      package: 'app',
      primaryInput: nestedInput,
      blockedAssets: {nestedBlocked},
    );
    expect(io.outputs, isNot(same(outerOutputs)));
    expect(await io.readAsBytes(nestedInput), [2]);
    await expectLater(
      io.readAsBytes(outerInput),
      throwsA(isA<AssetNotFoundException>()),
    );
    await io.writeAsString(nestedOutput, 'nested');
    expect(io.outputs[nestedOutput], isNotNull);
    expect(io.outputs[outerOutput], isNull);

    io.endAction();

    expect(io.outputs, same(outerOutputs));
    expect(io.outputs[outerOutput], isNotNull);
    expect(io.outputs[nestedOutput], isNull);
    expect(await io.readAsBytes(outerInput), [1]);
    await expectLater(
      io.readAsBytes(nestedInput),
      throwsA(isA<AssetNotFoundException>()),
    );

    io.beginAction(
      rpc: nestedRpc,
      package: 'app',
      primaryInput: nestedBlocked,
      blockedAssets: {nestedBlocked},
    );
    await expectLater(
      io.readAsBytes(nestedBlocked),
      throwsA(isA<AssetNotFoundException>()),
    );
    io.endAction();

    io.beginAction(
      rpc: outerRpc,
      package: 'app',
      primaryInput: outerBlocked,
      blockedAssets: {outerBlocked},
    );
    await expectLater(
      io.readAsBytes(outerBlocked),
      throwsA(isA<AssetNotFoundException>()),
    );
    io.endAction();

    io.endAction();
    expect(io.outputs, isEmpty);
  });
}

RpcSession _rpc() => RpcSession(
  FrameReader(Stream<List<int>>.empty()),
  FrameWriter(IOSink(_DiscardingConsumer())),
  buildId: 1,
  phase: 0,
  postProcess: false,
);

class _DiscardingConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}
}
