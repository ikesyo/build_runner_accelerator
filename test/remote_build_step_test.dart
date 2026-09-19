import 'dart:async';
import 'dart:io';

import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:build_runner_accelerator/src/remote_build_step.dart';
import 'package:test/test.dart';

void main() {
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
