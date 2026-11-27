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
    'worker prefetches batch inputs, reuses can_read path, and restores reset readability',
    () async {
      final dir = Directory('.dart_tool').createTempSync('batch-prefetch-');
      final relDir = dir.path.replaceAll(r'\', '/');
      final fileA = File('${dir.path}/a.txt')..writeAsStringSync('alpha');
      final fileB = File('${dir.path}/b.txt')..writeAsStringSync('beta');
      final fileC = File('${dir.path}/c.txt')..writeAsStringSync('gamma');
      final filePhase1 = File('${dir.path}/phase1.txt')
        ..writeAsStringSync('p1');
      final filePhase2 = File('${dir.path}/phase2.txt')
        ..writeAsStringSync('p2');
      final assetA = 'build_runner_accelerator|$relDir/a.txt';
      final assetB = 'build_runner_accelerator|$relDir/b.txt';
      final assetC = 'build_runner_accelerator|$relDir/c.txt';
      final assetPhase1 = 'build_runner_accelerator|$relDir/phase1.txt';
      final assetPhase2 = 'build_runner_accelerator|$relDir/phase2.txt';
      final committedAsset = 'build_runner_accelerator|$relDir/a.out';
      final phase1Output = 'build_runner_accelerator|$relDir/phase1.out';
      final phase2Output = 'build_runner_accelerator|$relDir/phase2.out';
      final diskFiles = <String, String>{
        assetA: fileA.absolute.path,
        assetB: fileB.absolute.path,
        assetC: fileC.absolute.path,
        assetPhase1: filePhase1.absolute.path,
        assetPhase2: filePhase2.absolute.path,
      };

      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('test/batch_prefetch_worker.dart').absolute.path,
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
        bool allowCanReadPath = true,
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
            } else if (op == 'can_read') {
              final asset = reply['asset'] as String;
              final path = diskFiles[asset];
              await writer.send({
                'v': 1,
                'type': 'asset_response',
                'id': reqId,
                'ok': true,
                'value': path != null,
                if (allowCanReadPath && path != null) 'path': path,
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
        int phase = 0,
        bool postProcess = false,
        String? extraRead,
      }) => {
        'id': id,
        'builder': postProcess ? 'prefetch_test:post' : 'prefetch_test:read',
        'kind': postProcess ? 'post_process' : 'normal',
        'instance_key': postProcess ? 'post' : 'read-${extraRead ?? 'self'}',
        'input': input,
        'phase': phase,
        'is_root': true,
        'options': {if (extraRead != null) 'extra_read': extraRead},
        'triggers': <dynamic>[],
        'allowed_outputs': [output],
      };

      // 1. Multi-request normal batch: 1 resolve_assets RPC, 0 can_read, 0 read.
      final (batchReply, batchRpcs) = await exchange({
        'type': 'build_batch',
        'blocked_assets': <String>[],
        'requests': [
          request(id: 0, input: assetA, output: committedAsset),
          request(
            id: 1,
            input: assetB,
            output: 'build_runner_accelerator|$relDir/b.out',
          ),
        ],
      });
      expect(batchReply['type'], 'build_batch_result');
      expect(batchRpcs.map((r) => r['op']).toList(), ['resolve_assets']);
      expect(batchRpcs.single['assets'], [assetA, assetB]);
      final batchResults = (batchReply['results'] as List).cast<JsonMap>();
      expect(batchResults[0]['stock_inputs'], [assetA]);
      expect(batchResults[1]['stock_inputs'], [assetB]);

      // 2. Single-request normal batch: 0 resolve_assets, 1 can_read (with path), 0 read.
      final (singleReply, singleRpcs) = await exchange({
        'type': 'build_batch',
        'blocked_assets': <String>[],
        'requests': [
          request(
            id: 0,
            input: assetC,
            output: 'build_runner_accelerator|$relDir/c.out',
          ),
        ],
      });
      expect(singleReply['type'], 'build_batch_result');
      expect(singleRpcs.map((r) => r['op']).toList(), ['can_read']);
      expect(singleRpcs.single['asset'], assetC);

      // 3. Post-process batch: 0 resolve_assets, 0 can_read, 0 read.
      final (postReply, postRpcs) = await exchange({
        'type': 'build_batch',
        'blocked_assets': <String>[],
        'requests': [
          request(
            id: 0,
            input: assetA,
            output: committedAsset,
            postProcess: true,
          ),
          request(
            id: 1,
            input: assetB,
            output: 'build_runner_accelerator|$relDir/b.out',
            postProcess: true,
          ),
        ],
      });
      expect(postReply['type'], 'build_batch_result');
      expect(postRpcs, isEmpty);

      // 4. Commit a.out via reset_resolver overlay_blob; reading that
      // earlier-phase output from a distinct phase 1 action must incur 0
      // can_read and 0 read RPCs and observe the committed overlay bytes.
      final blobBytes = utf8.encode('committed-alpha');
      final blobFile = File('${dir.path}/overlay.blob')
        ..writeAsBytesSync(blobBytes);
      final (resetReply, _) = await exchange({
        'type': 'reset_resolver',
        'incremental': true,
        'updated_sources': [committedAsset],
        'deleted_sources': <String>[],
        'updated_cache': <String>[],
        'deleted_cache': <String>[],
        'overlay_blob': {
          'path': blobFile.absolute.path,
          'length': blobBytes.length,
          'index': {
            committedAsset: {'offset': 0, 'length': blobBytes.length},
          },
        },
      });
      expect(resetReply['type'], 'reset_resolver');

      final (phase1Reply, phase1Rpcs) = await exchange({
        'type': 'build_batch',
        'blocked_assets': <String>[phase1Output],
        'requests': [
          request(
            id: 0,
            input: assetPhase1,
            output: phase1Output,
            phase: 1,
            extraRead: committedAsset,
          ),
        ],
      });
      expect(phase1Reply['type'], 'build_batch_result');
      expect(phase1Rpcs, isEmpty);
      final phase1Results = (phase1Reply['results'] as List).cast<JsonMap>();
      expect(phase1Results.single['stock_inputs'], [committedAsset]);
      final phase1Outputs = (phase1Results.single['outputs'] as List)
          .cast<JsonMap>();
      expect(phase1Outputs.single['asset'], phase1Output);
      expect(phase1Outputs.single['content'], 'committed-alpha');

      // 5. Delete a.out via reset_resolver; a distinct phase 2 action must
      // query Rust via can_read and observe that the deleted output is missing.
      final (deleteResetReply, _) = await exchange({
        'type': 'reset_resolver',
        'incremental': true,
        'updated_sources': <String>[],
        'deleted_sources': [committedAsset],
        'updated_cache': <String>[],
        'deleted_cache': <String>[],
        'overlay_blob': null,
      });
      expect(deleteResetReply['type'], 'reset_resolver');

      final (phase2Reply, phase2Rpcs) = await exchange({
        'type': 'build_batch',
        'blocked_assets': <String>[phase2Output],
        'requests': [
          request(
            id: 0,
            input: assetPhase2,
            output: phase2Output,
            phase: 2,
            extraRead: committedAsset,
          ),
        ],
      });
      expect(phase2Reply['type'], 'build_batch_result');
      expect(phase2Rpcs.map((r) => r['op']).toList(), ['can_read']);
      expect(phase2Rpcs.single['asset'], committedAsset);
      final phase2Results = (phase2Reply['results'] as List).cast<JsonMap>();
      expect(phase2Results.single['stock_inputs'], [committedAsset]);
      final phase2Outputs = (phase2Results.single['outputs'] as List)
          .cast<JsonMap>();
      expect(phase2Outputs.single['asset'], phase2Output);
      expect(phase2Outputs.single['content'], '<missing>');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
