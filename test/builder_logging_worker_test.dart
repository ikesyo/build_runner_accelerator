import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/frontend_binary_resolver.dart'
    show buildRunnerAcceleratorVersion;
import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:test/test.dart';

// The Dart worker's request reader decodes BRAB asset responses. This test is
// its peer, so strip BRAR output bytes after retaining the result metadata.
Stream<List<int>> resultMetadata(Stream<List<int>> input) async* {
  final pending = <int>[];
  await for (final chunk in input) {
    pending.addAll(chunk);
    while (pending.length >= 4) {
      final length = ByteData.sublistView(
        Uint8List.fromList(pending.sublist(0, 4)),
      ).getUint32(0);
      if (pending.length < length + 4) break;
      final payload = pending.sublist(4, length + 4);
      pending.removeRange(0, length + 4);
      if (payload.length >= 8 &&
          utf8.decode(payload.sublist(0, 4), allowMalformed: true) == 'BRAR') {
        final metadataLength = ByteData.sublistView(
          Uint8List.fromList(payload.sublist(4, 8)),
        ).getUint32(0);
        final header = ByteData(4)..setUint32(0, metadataLength);
        yield [
          ...header.buffer.asUint8List(),
          ...payload.sublist(8, 8 + metadataLength),
        ];
      } else {
        final header = ByteData(4)..setUint32(0, payload.length);
        yield [...header.buffer.asUint8List(), ...payload];
      }
    }
  }
}

void main() {
  test(
    'logged severe fails normal/post actions and does not leak to next action',
    () async {
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('test/builder_logging_worker.dart').absolute.path,
      ]);
      final diagnostics = StringBuffer();
      final stderrDone = child.stderr
          .transform(utf8.decoder)
          .forEach(diagnostics.write);
      addTearDown(() async {
        child.kill();
        await child.exitCode;
        await stderrDone;
      });
      final reader = FrameReader(resultMetadata(child.stdout));
      final writer = FrameWriter(child.stdin);
      var sequence = 0;
      Future<JsonMap> send(JsonMap message) async {
        final id = ++sequence;
        await writer.send({'v': 1, 'id': id, ...message});
        final result = await reader.next().timeout(
          const Duration(seconds: 90),
          onTimeout: () => throw StateError('worker timed out: $diagnostics'),
        );
        expect(result?['id'], id);
        return result!;
      }

      await send({
        'type': 'initialize',
        'root': Directory.current.absolute.path,
        'package': 'build_runner_accelerator',
        'phase_count': 1,
        'input_restrictions': <String, List<String>>{},
        'resolver_mode': 'dart_local',
        'accelerator_version': buildRunnerAcceleratorVersion,
      });
      Future<JsonMap> build({bool post = false, bool severe = true}) => send({
        'type': 'build',
        'builder': post ? 'logging:post' : 'logging:normal',
        'kind': post ? 'post_process' : 'normal',
        'instance_key': 'logging-$post-$severe',
        'input': 'build_runner_accelerator|lib/unused.dart',
        'phase': 0,
        'is_root': true,
        'options': {'severe': severe},
        'triggers': <dynamic>[],
        'blocked_assets': <String>[],
        'allowed_outputs': ['build_runner_accelerator|lib/unused.log.txt'],
      });
      for (final post in [false, true]) {
        final failed = await build(post: post);
        expect(failed['type'], 'error', reason: '$failed');
        expect(
          failed['error'],
          contains(post ? 'post severe' : 'normal severe'),
        );
        expect(failed, isNot(contains('outputs')));
        expect(failed, isNot(contains('deleted')));
        final success = await build(severe: false);
        expect(success['status'], 'success', reason: '$success');
        expect(success['outputs'], hasLength(1));
      }
      expect(diagnostics.toString(), contains('builder print'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
