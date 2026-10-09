import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:test/test.dart';
import 'dart:io';
import 'package:build_runner_accelerator/src/frontend_binary_resolver.dart'
    show buildRunnerAcceleratorVersion;

void main() {
  group('WorkerMessage.decode', () {
    test('decodes cache deltas on clean resolver resets', () {
      final message = WorkerMessage.decode(<String, dynamic>{
        'v': 1,
        'type': 'reset_resolver',
        'id': 4,
        'updated_sources': <dynamic>['app|lib/generated.dart'],
        'deleted_sources': <dynamic>['app|lib/old.dart'],
        'updated_cache': <dynamic>['app|lib/generated.json'],
        'deleted_cache': <dynamic>['app|lib/old.json'],
        'incremental': false,
        'overlay_blob': null,
      });

      expect(message, isA<WorkerResetResolverMessage>());
      final reset = message as WorkerResetResolverMessage;
      expect(reset.id, 4);
      expect(reset.updatedSources, ['app|lib/generated.dart']);
      expect(reset.deletedSources, ['app|lib/old.dart']);
      expect(reset.updatedCache, ['app|lib/generated.json']);
      expect(reset.deletedCache, ['app|lib/old.json']);
      expect(reset.incremental, isFalse);
      expect(reset.overlayBlob, isNull);
    });

    test('rejects resolver resets with omitted deltas', () {
      expect(
        () => WorkerMessage.decode(<String, dynamic>{
          'v': 1,
          'type': 'reset_resolver',
          'id': 5,
          'incremental': false,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires the resolver reset mode', () {
      expect(
        () => WorkerMessage.decode(<String, dynamic>{
          'v': 1,
          'type': 'reset_resolver',
          'id': 6,
          'updated_sources': <dynamic>[],
          'deleted_sources': <dynamic>[],
          'updated_cache': <dynamic>[],
          'deleted_cache': <dynamic>[],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'requires explicit overlay transport and preserves its descriptor',
      () {
        final message = <String, dynamic>{
          'v': 1,
          'type': 'reset_resolver',
          'id': 8,
          'updated_sources': ['app|lib/a.dart'],
          'deleted_sources': <String>[],
          'updated_cache': <String>[],
          'deleted_cache': <String>[],
          'incremental': true,
        };
        expect(() => WorkerMessage.decode(message), throwsFormatException);
        final blob = {
          'path': '/tmp/reset.blob',
          'length': 2,
          'index': {
            'app|lib/a.dart': {'offset': 0, 'length': 2},
          },
        };
        final reset =
            WorkerMessage.decode({...message, 'overlay_blob': blob})
                as WorkerResetResolverMessage;
        expect(reset.overlayBlob, equals(blob));
      },
    );

    test('rejects non-object overlay transport and non-string keys', () {
      final message = <String, dynamic>{
        'v': 1,
        'type': 'reset_resolver',
        'id': 9,
        'updated_sources': <String>[],
        'deleted_sources': <String>[],
        'updated_cache': <String>[],
        'deleted_cache': <String>[],
        'incremental': true,
      };
      for (final value in [
        1,
        'blob',
        <Object?>[],
        <Object?, Object?>{1: 'invalid key'},
      ]) {
        expect(
          () => WorkerMessage.decode({...message, 'overlay_blob': value}),
          throwsFormatException,
        );
      }
    });

    test('decodes initialize messages into typed values', () {
      final message = WorkerMessage.decode(<String, dynamic>{
        'v': 1,
        'type': 'initialize',
        'id': 7,
        'package': 'app',
        'root': Directory.current.absolute.path,
        'resolver_mode': 'dart_local',
        'phase_count': 3,
        'accelerator_version': buildRunnerAcceleratorVersion,
      });

      expect(message, isA<WorkerInitializeMessage>());
      final initialize = message as WorkerInitializeMessage;
      expect(initialize.id, 7);
      expect(initialize.package, 'app');
      expect(initialize.phaseCount, 3);
    });

    test('decodes build messages and normalizes optional fields once', () {
      final message = WorkerMessage.decode(<String, dynamic>{
        'v': 1,
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
        'v': 1,
        'type': 'build_batch',
        'id': 20,
        'blocked_assets': <dynamic>['app|lib/blocked.dart'],
        'requests': <dynamic>[
          <String, dynamic>{
            'id': 21,
            'builder': 'app|one',
            'input': 'app|lib/one.dart',
            'kind': 'normal',
            'phase': 0,
            'instance_key': 'one',
            'is_root': true,
            'options': <String, dynamic>{},
            'allowed_outputs': <String>[],
            'triggers': <dynamic>[],
          },
          <String, dynamic>{
            'id': 22,
            'builder': 'app|two',
            'input': 'app|lib/two.dart',
            'kind': 'normal',
            'phase': 0,
            'instance_key': 'two',
            'is_root': false,
            'options': <String, dynamic>{},
            'allowed_outputs': <String>[],
            'triggers': <dynamic>[],
          },
        ],
      });

      expect(message, isA<WorkerBuildBatchMessage>());
      final batch = message as WorkerBuildBatchMessage;
      expect(batch.id, 20);
      expect(batch.blockedAssets, ['app|lib/blocked.dart']);
      expect(batch.requests, hasLength(2));
      expect(batch.requests[0].id, 21);
      expect(batch.requests[0].isRoot, isTrue);
      expect(batch.requests[0].blockedAssets, ['app|lib/blocked.dart']);
      expect(batch.requests[0].blockedAssets, same(batch.blockedAssets));
      expect(batch.requests[1].id, 22);
      expect(batch.requests[1].isPostProcess, isFalse);
      expect(batch.requests[1].blockedAssets, same(batch.blockedAssets));
    });

    test('retains unsupported messages for the worker error response', () {
      final message = WorkerMessage.decode(<String, dynamic>{
        'v': 1,
        'type': 'future_message',
        'id': 30,
      });

      expect(message, isA<UnsupportedWorkerMessage>());
      final unsupported = message as UnsupportedWorkerMessage;
      expect(unsupported.id, 30);
      expect(unsupported.type, 'future_message');
    });
  });

  test('requires matching initialize version and valid phase count', () {
    final valid = <String, dynamic>{
      'v': 1,
      'type': 'initialize',
      'id': 1,
      'package': 'app',
      'root': Directory.current.absolute.path,
      'resolver_mode': 'dart_local',
      'phase_count': 1,
      'accelerator_version': buildRunnerAcceleratorVersion,
    };
    for (final field in [
      'v',
      'phase_count',
      'accelerator_version',
      'root',
      'resolver_mode',
    ]) {
      final missing = {...valid}..remove(field);
      expect(() => WorkerMessage.decode(missing), throwsFormatException);
    }
    for (final change in [
      {'v': 2},
      {'v': 1.0},
      {'accelerator_version': '0.0.0'},
      {'phase_count': 0},
      {'phase_count': 1.5},
    ]) {
      expect(
        () => WorkerMessage.decode({...valid, ...change}),
        throwsFormatException,
      );
    }
  });
  test('build requires current fields instead of legacy defaults', () {
    final valid = <String, dynamic>{
      'v': 1,
      'type': 'build',
      'id': 1,
      'builder': 'app|copy',
      'input': 'app|lib/a.dart',
      'phase': 0,
      'kind': 'normal',
      'instance_key': 'copy',
      'is_root': false,
      'options': <String, dynamic>{},
      'allowed_outputs': <String>[],
      'blocked_assets': <String>[],
      'triggers': <dynamic>[],
    };
    expect(WorkerMessage.decode(valid), isA<WorkerBuildMessage>());
    for (final field in [
      'phase',
      'kind',
      'instance_key',
      'is_root',
      'options',
      'allowed_outputs',
      'blocked_assets',
      'triggers',
    ]) {
      final missing = {...valid}..remove(field);
      expect(
        () => WorkerMessage.decode(missing),
        throwsFormatException,
        reason: field,
      );
    }
    for (final change in [
      {'is_root': 'true'},
      {'phase': 0.5},
      {'phase': -1},
      {'instance_key': ''},
      {'kind': 'unknown'},
    ]) {
      expect(
        () => WorkerMessage.decode({...valid, ...change}),
        throwsFormatException,
      );
    }
  });
  group('WorkerBuildRequest.fromJson', () {
    test('rejects malformed fields at the protocol boundary', () {
      expect(
        () => WorkerBuildRequest.fromJson(<String, dynamic>{
          'id': 1,
          'builder': 'app|copy',
          'input': 'app|lib/input.dart',
          'allowed_outputs': <dynamic>['app|lib/output.dart', 42],
        }, blockedAssets: const <String>[]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WorkerBuildRequest.fromJson(<String, dynamic>{
          'id': 1,
          'builder': 'app|copy',
          'input': 'app|lib/input.dart',
          'options': <dynamic, dynamic>{1: 'not a string key'},
        }, blockedAssets: const <String>[]),
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
        }, blockedAssets: const <String>[]),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires blocked_assets for direct build messages', () {
      expect(
        () => WorkerMessage.decode(<String, dynamic>{
          'v': 1,
          'type': 'build',
          'id': 1,
          'builder': 'app|copy',
          'input': 'app|lib/input.dart',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
