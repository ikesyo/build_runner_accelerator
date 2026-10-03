import 'dart:convert';
import 'dart:io';

import 'package:build_runner_accelerator/src/manifest/probe.dart';
import 'package:test/test.dart';

void main() {
  const valid = '{"digest":"digest","triggers":{}}';

  test('valid worker response avoids the source helper', () async {
    final result = await resolveManifestTriggerAttempts(
      worker: () async => decodeManifestTriggers(valid),
      helper: () async => throw StateError('must not run'),
    );
    expect(result.digest, 'digest');
  });

  test('malformed successful worker response retries the helper', () async {
    for (final response in [
      '{',
      '[]',
      '{}',
      '{"digest":1,"triggers":{}}',
      '{"digest":"d","triggers":{"builder":{}}}',
      '{"digest":"d","triggers":{"builder":[{"kind":"unknown","value":"x"}]}}',
      '{"digest":"d","triggers":{"builder":[{"kind":"import","value":1}]}}',
    ]) {
      var calls = 0;
      final result = await resolveManifestTriggerAttempts(
        worker: () async {
          final directory = await Directory.systemTemp.createTemp(
            'trigger-response-',
          );
          try {
            final script = File('${directory.path}/worker.dart');
            await script.writeAsString(
              "import 'dart:io'; void main(List<String> args) { "
              "File(args[0]).writeAsStringSync(${jsonEncode(response)}); }",
            );
            final file = File('${directory.path}/result.json');
            return await runManifestTriggerProcess(
              Platform.resolvedExecutable,
              [script.path, file.path],
              root: directory.path,
              result: file,
            );
          } finally {
            await directory.delete(recursive: true);
          }
        },
        helper: () async {
          calls++;
          return decodeManifestTriggers(valid);
        },
      );
      expect(result.digest, 'digest');
      expect(calls, 1);
    }
  });

  test('structured parser error preserves diagnostics without retry', () async {
    const diagnostic = 'Unsupported build trigger configuration:\nwarning';
    await expectLater(
      resolveManifestTriggerAttempts(
        worker: () async => decodeManifestTriggers(
          jsonEncode({
            'error': {
              'kind': 'unsupported-trigger-configuration',
              'message': diagnostic,
            },
          }),
        ),
        helper: () async => throw StateError('must not run'),
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', diagnostic),
      ),
    );
  });

  test('both unavailable attempts reject the manifest', () async {
    await expectLater(
      resolveManifestTriggerAttempts(
        worker: () async => null,
        helper: () async => null,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Official build trigger parsing failed',
        ),
      ),
    );
  });
}
