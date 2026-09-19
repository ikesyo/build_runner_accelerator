import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('WorkerMessage.decode', () {
    test('decodes initialize messages into typed values', () {
      final message = WorkerMessage.decode(<String, dynamic>{
        'type': 'initialize',
        'id': 7,
        'package': 'app',
        'phase_count': 3,
      });

      expect(message, isA<WorkerInitializeMessage>());
      final initialize = message as WorkerInitializeMessage;
      expect(initialize.id, 7);
      expect(initialize.package, 'app');
      expect(initialize.phaseCount, 3);
    });

    test('decodes build messages and normalizes optional fields once', () {
      final message = WorkerMessage.decode(<String, dynamic>{
        'type': 'build',
        'id': 12,
        'builder': 'app|copy',
        'input': 'app|lib/input.dart',
        'kind': 'normal',
        'allowed_outputs': <dynamic>['app|lib/output.dart'],
        'blocked_assets': <dynamic>['app|lib/blocked.dart'],
        'options': <String, dynamic>{'run_only_if_triggered': true},
        'phase': 2,
        'instance_key': 'copy#root',
        'is_root': false,
        'triggers': <dynamic>[
          <String, dynamic>{
            'kind': 'import',
            'value': 'package:shared/shared.dart',
          },
        ],
      });

      expect(message, isA<WorkerBuildMessage>());
      final request = (message as WorkerBuildMessage).request;
      expect(request.id, 12);
      expect(request.builder, 'app|copy');
      expect(request.input, 'app|lib/input.dart');
      expect(request.kind, 'normal');
      expect(request.isPostProcess, isFalse);
      expect(request.allowedOutputs, ['app|lib/output.dart']);
      expect(request.blockedAssets, ['app|lib/blocked.dart']);
      expect(request.options, {'run_only_if_triggered': true});
      expect(request.phase, 2);
      expect(request.instanceKey, 'copy#root');
      expect(request.isRoot, isFalse);
      expect(request.triggers.single.kind, 'import');
      expect(request.triggers.single.value, 'package:shared/shared.dart');
    });

    test('decodes build batches into typed child requests', () {
      final message = WorkerMessage.decode(<String, dynamic>{
        'type': 'build_batch',
        'id': 20,
        'requests': <dynamic>[
          <String, dynamic>{
            'id': 21,
            'builder': 'app|one',
            'input': 'app|lib/one.dart',
          },
          <String, dynamic>{
            'id': 22,
            'builder': 'app|two',
            'input': 'app|lib/two.dart',
            'kind': 'post_process',
          },
        ],
      });

      expect(message, isA<WorkerBuildBatchMessage>());
      final batch = message as WorkerBuildBatchMessage;
      expect(batch.id, 20);
      expect(batch.requests, hasLength(2));
      expect(batch.requests[0].id, 21);
      expect(batch.requests[0].isRoot, isTrue);
      expect(batch.requests[1].id, 22);
      expect(batch.requests[1].isPostProcess, isTrue);
    });

    test('retains unsupported messages for the worker error response', () {
      final message = WorkerMessage.decode(<String, dynamic>{
        'type': 'future_message',
        'id': 30,
      });

      expect(message, isA<UnsupportedWorkerMessage>());
      final unsupported = message as UnsupportedWorkerMessage;
      expect(unsupported.id, 30);
      expect(unsupported.type, 'future_message');
    });
  });

  group('WorkerBuildRequest.fromJson', () {
    test('rejects malformed fields at the protocol boundary', () {
      expect(
        () => WorkerBuildRequest.fromJson(<String, dynamic>{
          'id': 1,
          'builder': 'app|copy',
          'input': 'app|lib/input.dart',
          'allowed_outputs': <dynamic>['app|lib/output.dart', 42],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WorkerBuildRequest.fromJson(<String, dynamic>{
          'id': 1,
          'builder': 'app|copy',
          'input': 'app|lib/input.dart',
          'options': <dynamic, dynamic>{1: 'not a string key'},
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WorkerBuildRequest.fromJson(<String, dynamic>{
          'id': 1,
          'builder': 'app|copy',
          'input': 'app|lib/input.dart',
          'triggers': <dynamic>[
            <String, dynamic>{'kind': 'import'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('records asset RPC timing when a response arrives', () async {
    String? observedOperation;
    var observedTotalUs = -1;
    var observedSendUs = -1;
    var observedWaitUs = -1;
    final session = RpcSession(
      FrameReader(
        Stream<List<int>>.value(
          _frame(<String, dynamic>{
            'v': 1,
            'type': 'asset_response',
            'id': 1000,
            'ok': true,
          }),
        ),
      ),
      FrameWriter(IOSink(_DiscardingConsumer())),
      buildId: 7,
      phase: 2,
      postProcess: false,
      onTiming:
          ({
            required String operation,
            required int totalUs,
            required int sendUs,
            required int waitUs,
          }) {
            observedOperation = operation;
            observedTotalUs = totalUs;
            observedSendUs = sendUs;
            observedWaitUs = waitUs;
          },
    );

    await session.call('read', <String, dynamic>{'asset': 'app|lib/a.dart'});

    expect(observedOperation, 'read');
    expect(observedTotalUs, greaterThanOrEqualTo(observedSendUs));
    expect(observedSendUs, greaterThanOrEqualTo(0));
    expect(observedWaitUs, greaterThanOrEqualTo(0));
  });

  test(
    'hydrates shared-memory asset responses through the configured reader',
    () async {
      final reader = FrameReader(
        Stream<List<int>>.value(
          _frame(<String, dynamic>{
            'v': 1,
            'type': 'asset_response',
            'id': 1000,
            'ok': true,
            'encoding': 'shared_memory',
            'length': 3,
          }),
        ),
        sharedMemoryReader: (length) {
          expect(length, 3);
          return Uint8List.fromList(<int>[1, 2, 3]);
        },
      );

      final response = await reader.next();

      expect(response?['encoding'], 'shared_memory');
      expect(response?['bytes'], orderedEquals(<int>[1, 2, 3]));
    },
  );
}

List<int> _frame(Map<String, dynamic> message) {
  final payload = utf8.encode(jsonEncode(message));
  final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
  return <int>[...header.buffer.asUint8List(), ...payload];
}

class _DiscardingConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}
}
