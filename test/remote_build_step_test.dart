import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/asset_read_cache.dart';
import 'package:glob/glob.dart';
import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:build_runner_accelerator/src/remote_build_step.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('string reads preserve encoding, errors and read tracking', () async {
    final id = AssetId('app', 'lib/text.txt');
    final cache = AssetReadCache({id: utf8.encode('日本😀')});
    final io = RemoteAssetReaderWriter(readCache: cache, readableCache: {});
    expect(await io.readAsString(id, inArtifactTree: true), '日本😀');
    expect(io.observedReads, {id});
    cache[id] = [0xe9];
    expect(await io.readAsString(id, encoding: latin1), 'é');
    await expectLater(io.readAsString(id), throwsFormatException);
    expect(
      await io.readAsString(
        id,
        encoding: const Utf8Codec(allowMalformed: true),
      ),
      '\uFFFD',
    );
  });

  test(
    'public byte mutation and cache invalidation preserve MD5 and text',
    () async {
      final id = AssetId('app', 'lib/café.txt');
      final original = utf8.encode('original');
      final cache = AssetReadCache({id: original});
      final io = RemoteAssetReaderWriter(readCache: cache, readableCache: {});
      final expected = md5.convert([...original, ...id.toString().codeUnits]);
      final bytes = await io.readAsBytes(id);
      bytes[0] = 0;
      bytes.add(0);
      expect(await io.readAsString(id), 'original');
      expect(await io.digest(id, inArtifactTree: true), expected);
      expect(cache.contentFor(id)!.cachedContentDigest, isNull);
      for (final invalidate in [() => cache.remove(id), () => cache.clear()]) {
        invalidate();
        cache[id] = utf8.encode('replacement');
        expect(await io.readAsString(id), 'replacement');
        expect(
          await io.digest(id),
          md5.convert([
            ...utf8.encode('replacement'),
            ...id.toString().codeUnits,
          ]),
        );
      }
      expect(io.observedReads, {id});
    },
  );

  for (final postProcess in [false, true]) {
    test(
      'string and digest reads enforce ${postProcess ? 'post-process input' : 'blocked asset'} visibility',
      () async {
        final id = AssetId('app', 'lib/hidden.txt');
        final io = RemoteAssetReaderWriter(
          readCache: AssetReadCache({id: utf8.encode('cached')}),
          readableCache: {id},
        );
        io.beginAction(
          rpc: _rpc(),
          package: 'app',
          primaryInput: postProcess ? AssetId('app', 'lib/input.txt') : null,
          blockedAssets: postProcess ? {} : {id},
        );
        try {
          await expectLater(
            io.readAsString(id),
            throwsA(isA<AssetNotFoundException>()),
          );
          await expectLater(
            io.digest(id),
            throwsA(isA<AssetNotFoundException>()),
          );
          expect(io.observedReads, {id});
          if (postProcess) {
            final step = RemotePostProcessBuildStep(
              inputId: AssetId('app', 'lib/input.txt'),
              io: io,
              deletePrimaryInput: (_) {},
            );
            await expectLater(
              step.digest(id),
              throwsA(isA<InvalidInputException>()),
            );
          }
        } finally {
          io.endAction();
        }
      },
    );
  }

  test('same-action output rewrites never reuse an earlier digest', () async {
    final id = AssetId('app', 'lib/output.dart');
    final io = RemoteAssetReaderWriter(
      readCache: AssetReadCache({
        id: [0],
      }),
      readableCache: {},
    );
    io.beginAction(
      rpc: _rpc(),
      package: 'app',
      primaryInput: id,
      blockedAssets: {id},
    );
    try {
      await io.writeAsBytes(id, [1]);
      expect(await io.digest(id), md5.convert([1, ...id.toString().codeUnits]));
      final first = await io.readContent(id);
      final firstDigest = first.contentDigest;
      await io.writeAsBytes(id, [2]);
      expect(await io.digest(id), md5.convert([2, ...id.toString().codeUnits]));
      expect((await io.readContent(id)).contentDigest, isNot(firstDigest));
      // Even direct mutation of the output map cannot mutate an old snapshot.
      io.outputs[id]![0] = 3;
      expect((await io.readContent(id)).bytes, [3]);
      expect(first.bytes, [1]);
      expect(first.contentDigest, firstDigest);
    } finally {
      io.endAction();
    }
  });

  test(
    'builder mutation cannot change a collector snapshot or digest',
    () async {
      final id = AssetId('app', 'lib/main.dart');
      final cache = AssetReadCache({
        id: [1, 2, 3],
      });
      final io = RemoteAssetReaderWriter(readCache: cache, readableCache: {});
      final content = await io.readContent(id);
      final digest = content.contentDigest;
      final builderBytes = await io.readAsBytes(id);
      builderBytes[0] = 9;
      expect((await io.readContent(id)).contentDigest, digest);
      expect(await io.readAsBytes(id), [1, 2, 3]);
      expect(io.observedReads, {id});
    },
  );

  test(
    'visible glob results reuse readability and still track reads',
    () async {
      final id = AssetId('app', 'lib/model.g.part');
      final readable = <AssetId>{};
      final cache = AssetReadCache(<AssetId, List<int>>{});
      final io = RemoteAssetReaderWriter(
        readCache: cache,
        readableCache: readable,
      );
      final response = utf8.encode(
        jsonEncode({
          'id': 1000,
          'v': 1,
          'type': 'asset_response',
          'ok': true,
          'assets': [id.toString()],
        }),
      );
      final size = ByteData(4)..setUint32(0, response.length, Endian.big);
      io.beginAction(
        rpc: RpcSession(
          FrameReader(
            Stream.fromIterable([size.buffer.asUint8List(), response]),
          ),
          FrameWriter(IOSink(_DiscardingConsumer())),
          buildId: 1,
          phase: 1,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: {},
      );
      expect(await io.findAssets(Glob('lib/*.g.part')).toList(), [id]);
      expect(readable, {id});
      expect(io.observedReads, isEmpty);
      // There is no second response: canRead must reuse the positive answer.
      expect(await io.canRead(id), isTrue);
      expect(io.observedReads, {id});
      expect(io.observedGlobResults, {id});
      expect(cache, isEmpty);
      io.endAction();
      // Each action's visibility is checked before the shared positive cache.
      io.beginAction(
        rpc: _rpc(),
        package: 'app',
        primaryInput: null,
        blockedAssets: {id},
      );
      expect(await io.canRead(id), isFalse);
      await expectLater(
        io.readAsBytes(id),
        throwsA(isA<AssetNotFoundException>()),
      );
      io.endAction();
      // A post-process action may read only its primary input.
      io.beginAction(
        rpc: _rpc(),
        package: 'app',
        primaryInput: AssetId('app', 'lib/other.dart'),
        blockedAssets: {},
      );
      expect(await io.canRead(id), isFalse);
      io.endAction();
    },
  );

  for (final error in [
    'prefetch disabled during lazy builds',
    'resolve_assets response exceeds frame limit',
  ]) {
    test('declined prefetch ($error) preserves sequential reads', () async {
      final id = AssetId('app', 'lib/generated.dart');
      final cache = AssetReadCache(<AssetId, List<int>>{});
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

  test(
    'runAsResolver attributes reads across awaits to the resolver set',
    () async {
      final id = AssetId('app', 'lib/api.dart');
      final io = RemoteAssetReaderWriter(
        readCache: AssetReadCache({id: utf8.encode('x')}),
        readableCache: {},
      );
      await io.runAsResolver(() async {
        // The resolver's readability probe records its content preload
        // only after an await; the scope must span the whole call.
        await Future<void>.delayed(Duration.zero);
        await io.readAsBytes(id);
        await io.canRead(id);
      });
      expect(io.observedReads, isEmpty);
      expect(io.resolverObservedReads, {id});
      // A later direct read of the same asset lands in both sets, so
      // result assembly keeps it a direct read.
      await io.readAsBytes(id);
      expect(io.observedReads, {id});
      expect(io.resolverObservedReads, {id});
    },
  );

  test('a direct read concurrent with a resolver call stays direct', () async {
    final resolverId = AssetId('app', 'lib/resolved.dart');
    final directId = AssetId('app', 'lib/direct.dart');
    final io = RemoteAssetReaderWriter(
      readCache: AssetReadCache({
        resolverId: utf8.encode('r'),
        directId: utf8.encode('d'),
      }),
      readableCache: {},
    );
    final gate = Completer<void>();
    final resolverRead = io.runAsResolver(() async {
      await gate.future;
      await io.readAsBytes(resolverId);
    });
    // While the resolver call is still in flight, a direct read of
    // another asset must keep its own attribution.
    await io.readAsBytes(directId);
    gate.complete();
    await resolverRead;
    expect(io.observedReads, {directId});
    expect(io.resolverObservedReads, {resolverId});
  });

  test('a nested action inside a resolver scope starts unattributed', () async {
    final outerId = AssetId('app', 'lib/outer.dart');
    final nestedId = AssetId('app', 'lib/nested.dart');
    final io = RemoteAssetReaderWriter(
      readCache: AssetReadCache({
        outerId: utf8.encode('o'),
        nestedId: utf8.encode('n'),
      }),
      readableCache: {},
    );
    io.beginAction(
      rpc: _rpc(),
      package: 'app',
      primaryInput: outerId,
      blockedAssets: {},
    );
    await io.runAsResolver(() async {
      // A build triggered from inside the resolver call (an
      // optional builder, say) runs in this call chain, but its own
      // reads belong to the nested action, not to the resolver.
      io.beginAction(
        rpc: _rpc(),
        package: 'app',
        primaryInput: nestedId,
        blockedAssets: {},
      );
      await io.readAsBytes(nestedId);
      expect(io.observedReads, {nestedId});
      expect(io.resolverObservedReads, isEmpty);
      io.endAction();
      await io.readAsBytes(outerId);
    });
    expect(io.observedReads, isEmpty);
    expect(io.resolverObservedReads, {outerId});
    io.endAction();
  });

  test('nested actions restore the outer asset IO context', () async {
    final outerInput = AssetId('app', 'lib/outer.dart');
    final outerOutput = AssetId('app', 'lib/outer.txt');
    final nestedInput = AssetId('app', 'lib/nested.dart');
    final nestedOutput = AssetId('app', 'lib/nested.txt');
    final outerBlocked = AssetId('app', 'lib/outer_blocked.dart');
    final nestedBlocked = AssetId('app', 'lib/nested_blocked.dart');
    final io = RemoteAssetReaderWriter(
      readCache: AssetReadCache(<AssetId, List<int>>{
        outerInput: <int>[1],
        nestedInput: <int>[2],
        outerBlocked: <int>[3],
        nestedBlocked: <int>[4],
      }),
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

  test(
    'can_read with path satisfies subsequent read without a read RPC',
    () async {
      final id = AssetId('app', 'lib/model.dart');
      final cache = AssetReadCache(<AssetId, List<int>>{});
      final pathCache = <AssetId, String>{};
      final readable = <AssetId>{};
      final temporary = await Directory.systemTemp.createTemp('can-read-path-');
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/model.dart');
      await file.writeAsBytes([10, 20, 30]);

      final payload = utf8.encode(
        jsonEncode({
          'v': 1,
          'type': 'asset_response',
          'id': 1000,
          'ok': true,
          'value': true,
          'path': file.path,
        }),
      );
      final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
      final sink = IOSink(_DiscardingConsumer());
      addTearDown(sink.close);
      final io = RemoteAssetReaderWriter(
        readCache: cache,
        readableCache: readable,
        pathCache: pathCache,
      );
      io.beginAction(
        rpc: RpcSession(
          FrameReader(
            Stream.fromIterable([header.buffer.asUint8List(), payload]),
          ),
          FrameWriter(sink),
          buildId: 1,
          phase: 0,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: {},
      );
      // Only one response frame is supplied; readAsBytes must not issue a read RPC.
      expect(await io.canRead(id), isTrue);
      expect(readable, {id});
      expect(pathCache[id], file.path);
      expect(cache, isEmpty);

      expect(await io.readAsBytes(id), [10, 20, 30]);
      expect(pathCache, isEmpty);
      expect(cache[id], [10, 20, 30]);
      expect(io.observedReads, {id});
      io.endAction();
    },
  );

  test(
    'missing file at cached path evicts pathCache and readableCache',
    () async {
      final id = AssetId('app', 'lib/vanished.dart');
      final cache = AssetReadCache(<AssetId, List<int>>{});
      final pathCache = <AssetId, String>{};
      final readable = <AssetId>{};
      final temporary = await Directory.systemTemp.createTemp('vanished-path-');
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/vanished.dart');
      await file.writeAsBytes([1]);

      final payload = utf8.encode(
        jsonEncode({
          'v': 1,
          'type': 'asset_response',
          'id': 1000,
          'ok': true,
          'value': true,
          'path': file.path,
        }),
      );
      final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
      final sink = IOSink(_DiscardingConsumer());
      addTearDown(sink.close);
      final io = RemoteAssetReaderWriter(
        readCache: cache,
        readableCache: readable,
        pathCache: pathCache,
      );
      io.beginAction(
        rpc: RpcSession(
          FrameReader(
            Stream.fromIterable([header.buffer.asUint8List(), payload]),
          ),
          FrameWriter(sink),
          buildId: 1,
          phase: 0,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: {},
      );
      expect(await io.canRead(id), isTrue);
      await file.delete();
      await expectLater(
        io.readAsBytes(id),
        throwsA(isA<AssetNotFoundException>()),
      );
      expect(pathCache, isEmpty);
      expect(readable, isEmpty);
      expect(cache, isEmpty);
      io.endAction();
    },
  );

  test(
    'prefetchAssets caches paths lazily without touching observedReads',
    () async {
      final readId = AssetId('app', 'lib/a.dart');
      final unreadId = AssetId('app', 'lib/b.dart');
      final cache = AssetReadCache(<AssetId, List<int>>{});
      final pathCache = <AssetId, String>{};
      final readable = <AssetId>{};
      final temporary = await Directory.systemTemp.createTemp('lazy-prefetch-');
      addTearDown(() => temporary.delete(recursive: true));
      final fileA = File('${temporary.path}/a.dart')..writeAsBytesSync([7, 8]);
      final missingB = '${temporary.path}/b_never_read.dart';

      final payload = utf8.encode(
        jsonEncode({
          'v': 1,
          'type': 'asset_response',
          'id': 1000,
          'ok': true,
          'assets': [
            {'status': 'path', 'path': fileA.path},
            {'status': 'path', 'path': missingB},
          ],
        }),
      );
      final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
      final sink = IOSink(_DiscardingConsumer());
      addTearDown(sink.close);
      final io = RemoteAssetReaderWriter(
        readCache: cache,
        readableCache: readable,
        pathCache: pathCache,
      );
      io.beginAction(
        rpc: RpcSession(
          FrameReader(
            Stream.fromIterable([header.buffer.asUint8List(), payload]),
          ),
          FrameWriter(sink),
          buildId: 0,
          phase: 0,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: {},
      );
      await io.prefetchAssets([readId, unreadId]);
      // Neither file is read eagerly and observedReads remains untouched.
      expect(cache, isEmpty);
      expect(pathCache, {readId: fileA.path, unreadId: missingB});
      expect(readable, {readId, unreadId});
      expect(io.observedReads, isEmpty);

      // Reading readId uses the cached path with zero additional RPCs.
      expect(await io.canRead(readId), isTrue);
      expect(await io.readAsBytes(readId), [7, 8]);
      expect(io.observedReads, {readId});
      expect(cache[readId], [7, 8]);
      expect(pathCache.containsKey(readId), isFalse);
      expect(pathCache[unreadId], missingB);
      io.endAction();
    },
  );

  test(
    'preferGlobCache uses one list_visible_assets RPC for repeated globs and preserves source-before-generated order',
    () async {
      final cache = AssetReadCache(<AssetId, List<int>>{});
      final readable = <AssetId>{};
      final visibleCache = VisiblePackageAssetsCache();
      final sent = _RecordingConsumer();
      final sink = IOSink(sent);
      addTearDown(sink.close);

      final responseFrame = _encodeJsonFrame({
        'v': 1,
        'type': 'asset_response',
        'id': 1000,
        'ok': true,
        'sources': ['lib/a.dart', 'lib/b.dart', 'lib/m_001.dart'],
        'generated': [
          'lib/a.json.g.part',
          'lib/m_001.blocked.g.part',
          'lib/m_001.json.g.part',
        ],
      });
      final blocked = <AssetId>{AssetId('app', 'lib/m_001.blocked.g.part')};
      final io = RemoteAssetReaderWriter(
        readCache: cache,
        readableCache: readable,
        visibleAssetsCache: visibleCache,
      );
      io.beginAction(
        rpc: RpcSession(
          FrameReader(Stream.fromIterable([responseFrame])),
          FrameWriter(sink),
          buildId: 0,
          phase: 1,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: blocked,
        preferGlobCache: true,
      );

      final m1 = await io.findAssets(Glob('lib/m_001.*.g.part')).toList();
      expect(m1, [AssetId('app', 'lib/m_001.json.g.part')]);
      // Only matched members are added to readableCache / observedGlobResults.
      expect(readable, {AssetId('app', 'lib/m_001.json.g.part')});

      // Second glob in the same phase hits cache with zero extra RPCs and keeps
      // sources before generated in UTF-16 order.
      final allLib = await io.findAssets(Glob('lib/a*')).toList();
      expect(allLib, [
        AssetId('app', 'lib/a.dart'),
        AssetId('app', 'lib/a.json.g.part'),
      ]);
      expect(io.observedGlobs, {
        const ObservedGlob(package: 'app', pattern: 'lib/m_001.*.g.part'),
        const ObservedGlob(package: 'app', pattern: 'lib/a*'),
      });
      expect(
        io.observedGlobMembers[const ObservedGlob(
          package: 'app',
          pattern: 'lib/a*',
        )],
        allLib,
      );
      io.endAction();
      await sink.flush();

      final requests = sent.decodedFrames();
      expect(requests.map((r) => r['op']).toList(), ['list_visible_assets']);
      expect(requests.single['package'], 'app');
    },
  );

  test(
    'single-action globs stay on find_assets for the first call and upgrade on the second',
    () async {
      final visibleCache = VisiblePackageAssetsCache();
      final sent = _RecordingConsumer();
      final sink = IOSink(sent);
      addTearDown(sink.close);

      final frames = [
        _encodeJsonFrame({
          'v': 1,
          'type': 'asset_response',
          'id': 1000,
          'ok': true,
          'assets': ['app|lib/a.g.part'],
        }),
        _encodeJsonFrame({
          'v': 1,
          'type': 'asset_response',
          'id': 1001,
          'ok': true,
          'sources': ['lib/a.dart', 'lib/b.dart'],
          'generated': ['lib/a.g.part', 'lib/b.g.part'],
        }),
      ];
      final io = RemoteAssetReaderWriter(
        readCache: AssetReadCache(<AssetId, List<int>>{}),
        readableCache: <AssetId>{},
        visibleAssetsCache: visibleCache,
      );
      io.beginAction(
        rpc: RpcSession(
          FrameReader(Stream.fromIterable(frames)),
          FrameWriter(sink),
          buildId: 0,
          phase: 1,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: const <AssetId>{},
        preferGlobCache: false,
      );

      expect(await io.findAssets(Glob('lib/a.*.part')).toList(), [
        AssetId('app', 'lib/a.g.part'),
      ]);
      expect(await io.findAssets(Glob('lib/b.*.part')).toList(), [
        AssetId('app', 'lib/b.g.part'),
      ]);
      // Third call hits the cached listing with zero additional RPCs.
      expect(await io.findAssets(Glob('lib/*.dart')).toList(), [
        AssetId('app', 'lib/a.dart'),
        AssetId('app', 'lib/b.dart'),
      ]);
      io.endAction();
      await sink.flush();

      expect(sent.decodedFrames().map((r) => r['op']).toList(), [
        'find_assets',
        'list_visible_assets',
      ]);
    },
  );

  test(
    'declined list_visible_assets falls back to find_assets without retrying in the same phase',
    () async {
      final visibleCache = VisiblePackageAssetsCache();
      final sent = _RecordingConsumer();
      final sink = IOSink(sent);
      addTearDown(sink.close);

      final frames = [
        _encodeJsonFrame({
          'v': 1,
          'type': 'asset_response',
          'id': 1000,
          'ok': false,
          'error': 'visible asset listing disabled during lazy builds',
        }),
        _encodeJsonFrame({
          'v': 1,
          'type': 'asset_response',
          'id': 1001,
          'ok': true,
          'assets': ['app|lib/a.g.part'],
        }),
        _encodeJsonFrame({
          'v': 1,
          'type': 'asset_response',
          'id': 1002,
          'ok': true,
          'assets': ['app|lib/b.g.part'],
        }),
      ];
      final io = RemoteAssetReaderWriter(
        readCache: AssetReadCache(<AssetId, List<int>>{}),
        readableCache: <AssetId>{},
        visibleAssetsCache: visibleCache,
      );
      io.beginAction(
        rpc: RpcSession(
          FrameReader(Stream.fromIterable(frames)),
          FrameWriter(sink),
          buildId: 0,
          phase: 1,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: const <AssetId>{},
        preferGlobCache: true,
      );

      expect(await io.findAssets(Glob('lib/a.*.part')).toList(), [
        AssetId('app', 'lib/a.g.part'),
      ]);
      expect(await io.findAssets(Glob('lib/b.*.part')).toList(), [
        AssetId('app', 'lib/b.g.part'),
      ]);
      io.endAction();
      await sink.flush();

      expect(sent.decodedFrames().map((r) => r['op']).toList(), [
        'list_visible_assets',
        'find_assets',
        'find_assets',
      ]);
    },
  );

  test(
    'complex glob syntax bypasses list_visible_assets and phase changes isolate cached listings',
    () async {
      final visibleCache = VisiblePackageAssetsCache();
      final sent = _RecordingConsumer();
      final sink = IOSink(sent);
      addTearDown(sink.close);

      final frames = [
        _encodeJsonFrame({
          'v': 1,
          'type': 'asset_response',
          'id': 1000,
          'ok': true,
          'assets': ['app|lib/a.dart'],
        }),
        _encodeJsonFrame({
          'v': 1,
          'type': 'asset_response',
          'id': 1001,
          'ok': true,
          'sources': ['lib/a.dart'],
          'generated': <String>[],
        }),
        _encodeJsonFrame({
          'v': 1,
          'type': 'asset_response',
          'id': 1000,
          'ok': true,
          'sources': ['lib/a.dart'],
          'generated': ['lib/a.g.part'],
        }),
      ];
      final reader = FrameReader(Stream.fromIterable(frames));
      final writer = FrameWriter(sink);
      final io = RemoteAssetReaderWriter(
        readCache: AssetReadCache(<AssetId, List<int>>{}),
        readableCache: <AssetId>{},
        visibleAssetsCache: visibleCache,
      );

      io.beginAction(
        rpc: RpcSession(
          reader,
          writer,
          buildId: 0,
          phase: 0,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: const <AssetId>{},
        preferGlobCache: true,
      );
      // Brace alternation bypasses list_visible_assets.
      expect(await io.findAssets(Glob('lib/{a,b}.dart')).toList(), [
        AssetId('app', 'lib/a.dart'),
      ]);
      // Simple glob in phase 0 populates phase 0 cache.
      expect(await io.findAssets(Glob('lib/*.g.part')).toList(), isEmpty);
      io.endAction();

      // Phase 1 must not reuse phase 0's cached listing.
      io.beginAction(
        rpc: RpcSession(
          reader,
          writer,
          buildId: 0,
          phase: 1,
          postProcess: false,
        ),
        package: 'app',
        primaryInput: null,
        blockedAssets: const <AssetId>{},
        preferGlobCache: true,
      );
      expect(await io.findAssets(Glob('lib/*.g.part')).toList(), [
        AssetId('app', 'lib/a.g.part'),
      ]);
      io.endAction();
      await sink.flush();

      final requests = sent.decodedFrames();
      expect(requests.map((r) => r['op']).toList(), [
        'find_assets',
        'list_visible_assets',
        'list_visible_assets',
      ]);
      expect(requests[1]['phase'], 0);
      expect(requests[2]['phase'], 1);
    },
  );
}

List<int> _encodeJsonFrame(JsonMap message) {
  final payload = utf8.encode(jsonEncode(message));
  final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
  return [...header.buffer.asUint8List(), ...payload];
}

RpcSession _rpc() => RpcSession(
  FrameReader(Stream<List<int>>.empty()),
  FrameWriter(IOSink(_DiscardingConsumer())),
  buildId: 1,
  phase: 0,
  postProcess: false,
);

class _RecordingConsumer implements StreamConsumer<List<int>> {
  final List<int> _bytes = <int>[];

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _bytes.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}

  List<JsonMap> decodedFrames() {
    final frames = <JsonMap>[];
    final data = Uint8List.fromList(_bytes);
    var offset = 0;
    while (offset + 4 <= data.length) {
      final length = ByteData.sublistView(
        data,
        offset,
        offset + 4,
      ).getUint32(0, Endian.big);
      offset += 4;
      final payload = data.sublist(offset, offset + length);
      offset += length;
      frames.add(jsonDecode(utf8.decode(payload)) as JsonMap);
    }
    return frames;
  }
}

class _DiscardingConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}
}
