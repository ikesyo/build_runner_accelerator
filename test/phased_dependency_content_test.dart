import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build/build.dart';
import 'package:build_runner/src/build/asset_content.dart';
import 'package:build_runner/src/build/resolver/analysis_driver_filesystem.dart';
import 'package:build_runner_accelerator/src/asset_read_cache.dart';
import 'package:build_runner_accelerator/src/current_build_runtime.dart';
import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:build_runner_accelerator/src/remote_build_step.dart';
import 'package:package_config/package_config.dart';
import 'package:test/test.dart';

void main() {
  final id = AssetId('app', 'lib/input.dart');
  final other = AssetId('app', 'lib/other.dart');
  late AssetReadCache cache;
  late RemoteAssetReaderWriter io;
  late AnalysisDriverFilesystem analyzer;

  RemoteBuilderFilesystem filesystem({
    Map<AssetId, AssetContent> committed = const {},
  }) {
    final packages = buildPackagesFor(
      PackageConfig([Package('app', Uri.file('/app/'))]),
      'app',
    );
    return RemoteBuilderFilesystem(
      buildPackages: packages,
      buildState: RemoteBuildState(
        {'app'},
        phaseCount: 8,
        committedContents: committed,
      ),
      readerWriter: io,
    );
  }

  void action({
    Set<AssetId> blocked = const {},
    AssetId? primary,
    bool missing = false,
  }) {
    io.beginAction(
      rpc: _rpc(missing: missing),
      package: 'app',
      primaryInput: primary,
      blockedAssets: blocked,
    );
  }

  setUp(() {
    cache = AssetReadCache({
      id: utf8.encode("import 'other.dart'; class Input {}"),
      other: utf8.encode('class Other {}'),
    });
    io = RemoteAssetReaderWriter(readCache: cache, readableCache: {});
    analyzer = AnalysisDriverFilesystem();
  });

  test(
    'positive dep content uses the owned typed bytes without another copy',
    () async {
      final fs = filesystem();
      AssetContent? notified;
      fs.listenToContentUpdates((_, content) => notified = content);
      action();
      await fs.readPhased(0, id);
      expect(identical(notified!.bytes, cache.contentFor(id)!.bytes), isTrue);
      expect(notified!.bytes, isA<Uint8List>());
      expect(() => notified!.bytes[0] = 0, throwsUnsupportedError);
      io.endAction();
    },
  );

  test(
    'nested optional action checks its own visibility and restores the outer read context',
    () async {
      final fs = filesystem();
      fs.listenToContentUpdates((_, _) {});
      action();
      final first = await fs.readPhased(3, id);
      action(blocked: {id});
      expect((await fs.readPhased(1, id)).expiresAfter, 1);
      expect(io.observedReads, {id});
      io.endAction();
      expect((await fs.readPhased(3, id)).lastValue, first.lastValue);
      expect(io.observedReads, {id});
      io.endAction();
    },
  );

  test(
    'clean phase reset replays snapshot content into an empty Analyzer filesystem',
    () async {
      final firstFs = filesystem();
      analyzer.startBuild(
        builderFilesystem: firstFs,
        buildInputs: cleanBuildInputs(),
      );
      action();
      final first = await firstFs.readPhased(0, id);
      final firstVisible = analyzer.get('/app/lib/input.dart').content;
      expect(analyzer.get('/app/lib/input.dart').content, first.lastValue);
      io.endAction();
      final nextFs = filesystem();
      analyzer.startBuild(
        builderFilesystem: nextFs,
        buildInputs: cleanBuildInputs(),
      );
      expect(analyzer.get('/app/lib/input.dart').exists, isFalse);
      action();
      final next = await nextFs.readPhased(3, id);
      expect(next.lastValue, first.lastValue);
      expect(firstVisible, next.lastValue);
      expect(analyzer.get('/app/lib/input.dart').content, next.lastValue);
      expect(io.observedReads, {id});
      io.endAction();
    },
  );

  test(
    'empty and invalid UTF-8 values retain phase expiry and error reporting',
    () async {
      final fs = filesystem();
      fs.listenToContentUpdates((_, _) {});
      final errors = <String>[];
      final subscription = log.onRecord.listen(
        (record) => errors.add(record.message),
      );
      addTearDown(subscription.cancel);
      action();
      cache[id] = [];
      expect((await fs.readPhased(1, id)).expiresAfter, 1);
      cache[id] = [0xff];
      expect((await fs.readPhased(2, id)).expiresAfter, 2);
      expect(errors, contains('Dart source $id is not valid utf8.'));
      io.endAction();
    },
  );

  test(
    'warm snapshot never bypasses same-phase or post-process visibility',
    () async {
      final fs = filesystem();
      fs.listenToContentUpdates((_, _) {});
      action();
      await fs.readPhased(0, id);
      io.endAction();
      for (final primary in [null, other]) {
        action(blocked: primary == null ? {id} : {}, primary: primary);
        final hidden = await fs.readPhased(1, id);
        expect(hidden.values.last.value, '');
        expect(hidden.expiresAfter, 1);
        expect(io.observedReads, {id});
        io.endAction();
      }
    },
  );

  test(
    'missing generated asset expires and appears at a later phase',
    () async {
      cache.remove(id);
      final fs = filesystem();
      analyzer.startBuild(
        builderFilesystem: fs,
        buildInputs: cleanBuildInputs(),
      );
      action(missing: true);
      final missing = await fs.readPhased(1, id);
      expect(missing.values.last.value, '');
      expect(missing.expiresAfter, 1);
      expect(io.observedReads, {id});
      io.endAction();
      cache[id] = utf8.encode("export 'other.dart'; class Generated {}");
      action();
      final appeared = await fs.readPhased(2, id);
      expect(appeared.lastValue, contains('Generated'));
      expect(appeared.isComplete, isTrue);
      expect(analyzer.get('/app/lib/input.dart').content, appeared.lastValue);
      io.endAction();
    },
  );

  test(
    'replacement, deletion/rename and failure clear discard old snapshot bytes',
    () async {
      final fs = filesystem();
      fs.listenToContentUpdates((_, _) {});
      action();
      final original = await fs.readPhased(0, id);
      final oldSnapshot = cache.contentFor(id)!;
      final oldBytes = oldSnapshot.bytes;
      // Resolver reset deltas replace/remove the exact existing byte entry.
      cache[id] = utf8.encode("export 'other.dart'; class Changed {}");
      final changed = await fs.readPhased(2, id);
      expect(changed.lastValue, isNot(original.lastValue));
      expect(cache.contentFor(id)!.bytes, isNot(oldBytes));
      cache[other] = cache.remove(id)!;
      io.endAction();
      action(missing: true);
      expect((await fs.readPhased(3, id)).expiresAfter, 3);
      expect((await fs.readPhased(3, other)).lastValue, changed.lastValue);
      io.endAction();
      cache.clear();
      cache[id] = utf8.encode(original.lastValue);
      expect(identical(cache.contentFor(id), oldSnapshot), isFalse);
      action();
      expect((await fs.readPhased(4, id)).lastValue, original.lastValue);
      expect(identical(cache.contentFor(id)!.bytes, oldBytes), isFalse);
      io.endAction();
    },
  );

  test('action-local output rewrites expose the current bytes', () async {
    final fs = filesystem();
    fs.listenToContentUpdates((_, _) {});
    action(primary: id);
    await io.writeAsString(id, 'class First {}');
    final first = await fs.readPhased(0, id);
    await io.writeAsString(id, 'class Second {}');
    expect((await fs.readPhased(0, id)).lastValue, isNot(first.lastValue));
    io.endAction();
  });

  test(
    'public contentOf bytes stay mutable and cannot change dep snapshots',
    () async {
      final fs = filesystem();
      fs.listenToContentUpdates((_, _) {});
      action();
      final deps = await fs.readPhased(0, id);
      final public = await fs.contentOf(id);
      public.bytes[0] = 0;
      expect((await fs.readPhased(0, id)).lastValue, deps.lastValue);
      expect(utf8.decode(cache[id]!), deps.lastValue);
      io.endAction();
    },
  );

  test(
    'content listener remains single-registration and committed content is notified at start',
    () async {
      final content = AssetContent.string('class Committed {}');
      final fs = filesystem(committed: {id: content});
      analyzer.startBuild(
        builderFilesystem: fs,
        buildInputs: cleanBuildInputs(),
      );
      expect(() => fs.listenToContentUpdates((_, _) {}), throwsStateError);
      expect(
        analyzer.get('/app/lib/input.dart').content,
        content.stringValue(),
      );
      action();
      expect((await fs.readPhased(2, id)).lastValue, content.stringValue());
      io.endAction();
    },
  );
}

RpcSession _rpc({bool missing = false}) {
  final response = utf8.encode(
    jsonEncode({
      'type': 'asset_response',
      'id': 1000,
      'ok': true,
      'value': false,
    }),
  );
  final header = ByteData(4)..setUint32(0, response.length, Endian.big);
  return RpcSession(
    FrameReader(
      Stream.fromIterable(
        missing ? [header.buffer.asUint8List(), response] : <List<int>>[],
      ),
    ),
    FrameWriter(IOSink(_DiscardingConsumer())),
    buildId: 1,
    phase: 0,
    postProcess: false,
  );
}

class _DiscardingConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<void> close() async {}
}
