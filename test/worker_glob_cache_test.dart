import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/frontend_binary_resolver.dart'
    show buildRunnerAcceleratorVersion;
import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:test/test.dart';

Stream<List<int>> _resultMetadata(Stream<List<int>> input) async* {
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
        final metadata =
            jsonDecode(utf8.decode(payload.sublist(8, 8 + metadataLength)))
                as Map<String, dynamic>;
        var rawOffset = 8 + metadataLength;
        void attachOutputs(List<dynamic>? outputs) {
          if (outputs == null) return;
          for (final raw in outputs) {
            final output = raw as Map<String, dynamic>;
            final outputLength = output['length'] as int;
            output['content'] = utf8.decode(
              payload.sublist(rawOffset, rawOffset + outputLength),
            );
            rawOffset += outputLength;
          }
        }

        if (metadata['results'] case final List<dynamic> results) {
          for (final result in results) {
            attachOutputs((result as Map<String, dynamic>)['outputs'] as List?);
          }
        } else {
          attachOutputs(metadata['outputs'] as List?);
        }
        final encoded = utf8.encode(jsonEncode(metadata));
        final header = ByteData(4)..setUint32(0, encoded.length);
        yield [...header.buffer.asUint8List(), ...encoded];
      } else {
        final header = ByteData(4)..setUint32(0, payload.length);
        yield [...header.buffer.asUint8List(), ...payload];
      }
    }
  }
}

void main() {
  test(
    'worker caches list_visible_assets across batch actions, clears on reset_resolver, and falls back when declined',
    () async {
      final dir = Directory('.dart_tool').createTempSync('glob-cache-worker-');
      final relDir = dir.path.replaceAll(r'\', '/');
      final fileA = File('${dir.path}/a.dart')..writeAsStringSync('// a');
      final fileB = File('${dir.path}/b.dart')..writeAsStringSync('// b');
      final assetA = 'build_runner_accelerator|$relDir/a.dart';
      final assetB = 'build_runner_accelerator|$relDir/b.dart';
      final outA = 'build_runner_accelerator|$relDir/a.out';
      final outB = 'build_runner_accelerator|$relDir/b.out';
      final diskFiles = <String, String>{
        assetA: fileA.absolute.path,
        assetB: fileB.absolute.path,
      };

      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('test/glob_cache_worker.dart').absolute.path,
      ]);
      final diagnostics = StringBuffer();
      final stderrDone = child.stderr
          .transform(utf8.decoder)
          .forEach(diagnostics.write);
      addTearDown(() async {
        child.kill();
        await child.exitCode;
        await stderrDone;
        dir.deleteSync(recursive: true);
      });

      final reader = FrameReader(_resultMetadata(child.stdout));
      final writer = FrameWriter(child.stdin);
      var sequence = 0;

      Future<(JsonMap, List<JsonMap>)> exchange(
        JsonMap message, {
        List<String> visibleSources = const <String>[],
        List<String> visibleGenerated = const <String>[],
        bool declineListing = false,
        Map<String, List<String>> findResponses =
            const <String, List<String>>{},
      }) async {
        final id = ++sequence;
        await writer.send({'v': 1, 'id': id, ...message});
        final assetRequests = <JsonMap>[];
        while (true) {
          final reply = await reader.next().timeout(
            const Duration(seconds: 90),
            onTimeout: () => throw StateError('worker timed out: $diagnostics'),
          );
          expect(reply, isNotNull);
          if (reply!['type'] == 'asset_request') {
            assetRequests.add(reply);
            final op = reply['op'];
            final reqId = reply['id'];
            if (op == 'resolve_assets') {
              final assets = (reply['assets'] as List).cast<String>();
              await writer.send({
                'v': 1,
                'type': 'asset_response',
                'id': reqId,
                'ok': true,
                'assets': [
                  for (final asset in assets)
                    if (diskFiles[asset] case final path?)
                      {'status': 'path', 'path': path}
                    else
                      {'status': 'not_found'},
                ],
              });
            } else if (op == 'list_visible_assets') {
              if (declineListing) {
                await writer.send({
                  'v': 1,
                  'type': 'asset_response',
                  'id': reqId,
                  'ok': false,
                  'error': 'visible asset listing disabled during lazy builds',
                });
              } else {
                await writer.send({
                  'v': 1,
                  'type': 'asset_response',
                  'id': reqId,
                  'ok': true,
                  'sources': visibleSources,
                  'generated': visibleGenerated,
                });
              }
            } else if (op == 'find_assets') {
              final pattern = reply['pattern'] as String;
              await writer.send({
                'v': 1,
                'type': 'asset_response',
                'id': reqId,
                'ok': true,
                'assets': findResponses[pattern] ?? const <String>[],
              });
            } else {
              fail('Unexpected asset RPC op: $reply');
            }
            continue;
          }
          expect(reply['id'], id, reason: '$reply');
          return (reply, assetRequests);
        }
      }

      final (initReply, _) = await exchange({
        'type': 'initialize',
        'root': Directory.current.absolute.path,
        'package': 'build_runner_accelerator',
        'phase_count': 3,
        'input_restrictions': <String, List<String>>{},
        'resolver_mode': 'dart_local',
        'accelerator_version': buildRunnerAcceleratorVersion,
      });
      expect(initReply['type'], 'initialized');

      JsonMap request({
        required int id,
        required String input,
        required String output,
        required int phase,
      }) => {
        'id': id,
        'builder': 'glob_cache_test:find',
        'kind': 'normal',
        'instance_key': 'find',
        'input': input,
        'phase': phase,
        'is_root': true,
        'options': <String, dynamic>{},
        'triggers': <dynamic>[],
        'allowed_outputs': [output],
      };

      // 1. Multi-request batch in phase 0: issues 1 list_visible_assets and 0
      // find_assets, keeps source-before-generated ordering, hides blocked
      // assets, and preserves glob dependency metadata.
      final blockedPart = 'build_runner_accelerator|$relDir/a.blocked.part';
      final (phase0Reply, phase0Rpcs) = await exchange(
        {
          'type': 'build_batch',
          'blocked_assets': <String>[outA, outB, blockedPart],
          'requests': [
            request(id: 0, input: assetA, output: outA, phase: 0),
            request(id: 1, input: assetB, output: outB, phase: 0),
          ],
        },
        visibleSources: ['$relDir/a.src.part'],
        visibleGenerated: [
          '$relDir/a.blocked.part',
          '$relDir/a.g.part',
          '$relDir/b.g.part',
        ],
      );
      expect(phase0Reply['type'], 'build_batch_result');
      expect(phase0Rpcs.map((r) => r['op']).toList(), [
        'resolve_assets',
        'list_visible_assets',
      ]);
      final phase0Results = (phase0Reply['results'] as List).cast<JsonMap>();
      expect(
        ((phase0Results[0]['outputs'] as List).single as JsonMap)['content'],
        'build_runner_accelerator|$relDir/a.src.part\n'
        'build_runner_accelerator|$relDir/a.g.part',
      );
      expect(
        ((phase0Results[1]['outputs'] as List).single as JsonMap)['content'],
        'build_runner_accelerator|$relDir/b.g.part',
      );
      expect(phase0Results[0]['glob_reads'], [
        {'package': 'build_runner_accelerator', 'pattern': '$relDir/a.*.part'},
      ]);
      expect(phase0Results[0]['stock_globs'], {
        'build_runner_accelerator|$relDir/a.*.part': [
          'build_runner_accelerator|$relDir/a.src.part',
          'build_runner_accelerator|$relDir/a.g.part',
        ],
      });
      expect(phase0Results[1]['glob_reads'], [
        {'package': 'build_runner_accelerator', 'pattern': '$relDir/b.*.part'},
      ]);
      expect(phase0Results[1]['stock_globs'], {
        'build_runner_accelerator|$relDir/b.*.part': [
          'build_runner_accelerator|$relDir/b.g.part',
        ],
      });

      // 1b. A second batch in the same phase with reused blocked_assets hits
      // the cached listing with zero additional RPCs.
      final (phase0ReuseReply, phase0ReuseRpcs) = await exchange({
        'type': 'build_batch',
        'blocked_assets_reuse': true,
        'blocked_assets': <String>[],
        'requests': [
          request(id: 0, input: assetA, output: outA, phase: 0),
          request(id: 1, input: assetB, output: outB, phase: 0),
        ],
      });
      expect(phase0ReuseReply['type'], 'build_batch_result');
      expect(phase0ReuseRpcs, isEmpty);

      // 2. reset_resolver invalidates the cached listing even when phase and
      // reused blocked_assets stay identical, so newly generated parts appear.
      final (resetReply, _) = await exchange({
        'type': 'reset_resolver',
        'incremental': true,
        'updated_sources': <String>[],
        'deleted_sources': <String>[],
        'updated_cache': <String>[],
        'deleted_cache': <String>[],
        'overlay_blob': null,
      });
      expect(resetReply['type'], 'reset_resolver');

      final (afterResetReply, afterResetRpcs) = await exchange(
        {
          'type': 'build_batch',
          'blocked_assets_reuse': true,
          'blocked_assets': <String>[],
          'requests': [
            request(id: 0, input: assetA, output: outA, phase: 0),
            request(id: 1, input: assetB, output: outB, phase: 0),
          ],
        },
        visibleSources: const <String>[],
        visibleGenerated: ['$relDir/a.v2.part', '$relDir/b.v2.part'],
      );
      expect(afterResetReply['type'], 'build_batch_result');
      expect(afterResetRpcs.map((r) => r['op']).toList(), [
        'list_visible_assets',
      ]);
      final afterResetResults = (afterResetReply['results'] as List)
          .cast<JsonMap>();
      expect(
        ((afterResetResults[0]['outputs'] as List).single
            as JsonMap)['content'],
        'build_runner_accelerator|$relDir/a.v2.part',
      );
      expect(
        ((afterResetResults[1]['outputs'] as List).single
            as JsonMap)['content'],
        'build_runner_accelerator|$relDir/b.v2.part',
      );

      // 3. Declined list_visible_assets falls back cleanly to find_assets and
      // memoizes the decline so the second request skips retrying the listing.
      final (phase2Reply, phase2Rpcs) = await exchange(
        {
          'type': 'build_batch',
          'blocked_assets': <String>[outA, outB],
          'requests': [
            request(id: 0, input: assetA, output: outA, phase: 2),
            request(id: 1, input: assetB, output: outB, phase: 2),
          ],
        },
        declineListing: true,
        findResponses: {
          '$relDir/a.*.part': ['build_runner_accelerator|$relDir/a.lazy.part'],
          '$relDir/b.*.part': ['build_runner_accelerator|$relDir/b.lazy.part'],
        },
      );
      expect(phase2Reply['type'], 'build_batch_result');
      expect(phase2Rpcs.map((r) => r['op']).toList(), [
        'list_visible_assets',
        'find_assets',
        'find_assets',
      ]);
      final phase2Results = (phase2Reply['results'] as List).cast<JsonMap>();
      expect(
        ((phase2Results[0]['outputs'] as List).single as JsonMap)['content'],
        'build_runner_accelerator|$relDir/a.lazy.part',
      );
      expect(
        ((phase2Results[1]['outputs'] as List).single as JsonMap)['content'],
        'build_runner_accelerator|$relDir/b.lazy.part',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
