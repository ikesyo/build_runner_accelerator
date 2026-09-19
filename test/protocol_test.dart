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
}
