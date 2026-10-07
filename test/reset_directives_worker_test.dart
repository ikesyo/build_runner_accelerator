import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'phase reset compares pre-build and committed versions through delete/recreate and next build',
    () async {
      final dir = Directory('.dart_tool').createTempSync('reset-directives-');
      final package = 'build_runner_accelerator';
      final path = '${dir.path.replaceAll(r'\', '/')}/output.dart';
      final id = '$package|$path';
      File(path).writeAsStringSync("import 'a.dart';\nclass First {}");
      final child = await Process.start(
        Platform.resolvedExecutable,
        [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          File('test/reset_directives_worker.dart').absolute.path,
        ],
        environment: {
          'BUILD_RUNNER_ACCELERATOR_WALL_TRACE': '1',
          'BUILD_RUNNER_ACCELERATOR_METRICS': '1',
          'BUILD_RUNNER_ACCELERATOR_CACHE': '${dir.absolute.path}/cache',
        },
      );
      final reader = FrameReader(child.stdout);
      final writer = FrameWriter(child.stdin);
      final diagnostics = StreamQueue(
        child.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((line) => line.startsWith('BRA_RESET_TRACE ')),
      );
      addTearDown(() async {
        child.kill();
        await child.exitCode;
        await diagnostics.cancel();
        dir.deleteSync(recursive: true);
      });
      var sequence = 0;
      Future<void> send(JsonMap message) async {
        final request = ++sequence;
        await writer.send({'v': 1, 'id': request, ...message});
        final response = await reader.next().timeout(
          const Duration(seconds: 30),
        );
        expect(response?['id'], request);
        expect(
          response?['type'],
          message['type'] == 'initialize' ? 'initialized' : message['type'],
          reason: '$response',
        );
      }

      await send({'type': 'initialize', 'package': package, 'phase_count': 8});
      Future<Map<String, dynamic>> reset({
        String? content,
        bool deleted = false,
        bool cache = false,
      }) async {
        final bytes = utf8.encode(content ?? '');
        final blob = File('${dir.path}/reset.blob')..writeAsBytesSync(bytes);
        await send({
          'type': 'reset_resolver',
          'incremental': true,
          'updated_sources': content != null && !cache ? [id] : [],
          'updated_cache': content != null && cache ? [id] : [],
          'deleted_sources': deleted ? [id] : [],
          'deleted_cache': [],
          'overlay_blob': {
            'path': blob.absolute.path,
            'length': bytes.length,
            'index': content == null
                ? {}
                : {
                    id: {'offset': 0, 'length': bytes.length},
                  },
          },
        });
        return jsonDecode(
              (await diagnostics.next.timeout(
                const Duration(seconds: 30),
              )).substring('BRA_RESET_TRACE '.length),
            )
            as Map<String, dynamic>;
      }

      final first = await reset(content: "import 'a.dart';\nclass First {}");
      expect(first['graph_cleared'], false);
      expect(first['directive_stats']['old_reads'], 1);
      expect(first['directive_stats']['old_same_content_reuses'], 1);
      expect(first['directive_stats']['old_extracts'] ?? 0, 0);
      final same = await reset(
        content: "import 'a.dart';\nclass First {}",
        cache: true,
      );
      expect(same['graph_cleared'], false);
      expect(same['directive_stats']['updated_extracts'], 1);
      expect(same['directive_stats']['old_cache_hits'], 1);
      expect(same['directive_stats']['old_reads'], isNull);
      final body = await reset(content: "import 'a.dart';\nclass Body {}");
      expect(body['graph_cleared'], false);
      final changed = await reset(content: "import 'b.dart';\nclass Body {}");
      expect(changed['graph_cleared'], true);
      expect((await reset(deleted: true))['graph_cleared'], false);
      final recreated = await reset(content: "import 'b.dart';\nclass Body {}");
      expect(recreated['graph_cleared'], true);
      expect(recreated['directive_stats']['old_cache_misses'], 1);
      expect(recreated['directive_stats']['old_extracts'], 1);
      // A watch build replaces the resolver and discards build-scoped extraction.
      await send({'type': 'reset'});
      final next = await reset(content: "import 'b.dart';\nclass Body {}");
      expect(next['graph_cleared'], true);
      expect(next['directive_stats']['old_same_content_reuses'] ?? 0, 0);
      expect(next['directive_stats']['old_reads'], 1);
      // A first generated asset has no old file/graph entry; nonempty directives
      // alone must not cause an unnecessary clear.
      File(path).deleteSync();
      await send({'type': 'reset'});
      expect((await reset(content: "part of fresh;"))['graph_cleared'], false);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
