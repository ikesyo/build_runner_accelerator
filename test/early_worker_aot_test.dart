import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_runner_accelerator/src/manifest/probe.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File source, marker, executable;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('early-worker-aot-');
    source = File('${temporary.path}/worker.dart')..writeAsStringSync('worker');
    executable = File('${temporary.path}/worker')
      ..writeAsStringSync('executable');
    marker = File('${temporary.path}/ready.json');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  void ready() => marker.writeAsStringSync(
    jsonEncode({'state': 'ready', 'source': 'worker', 'path': executable.path}),
  );

  test(
    'waits for the invocation marker then checks exact source contents',
    () async {
      marker.writeAsStringSync('{"state":"pending"}');
      final timer = Timer(const Duration(milliseconds: 10), ready);
      try {
        expect(
          await waitForEarlyWorkerAot(marker.path, source.path),
          executable.path,
        );
      } finally {
        timer.cancel();
      }
      final timestamp = source.lastModifiedSync();
      source.writeAsStringSync('different');
      source.setLastModifiedSync(timestamp);
      expect(await waitForEarlyWorkerAot(marker.path, source.path), isNull);
    },
  );

  test('declines malformed, unavailable and missing artifacts', () async {
    for (final contents in ['bad JSON', '[]', '{"state":"unavailable"}']) {
      marker.writeAsStringSync(contents);
      expect(await waitForEarlyWorkerAot(marker.path, source.path), isNull);
    }
    ready();
    executable.deleteSync();
    expect(await waitForEarlyWorkerAot(marker.path, source.path), isNull);
    marker.deleteSync();
    expect(await waitForEarlyWorkerAot(marker.path, source.path), isNull);
  });

  test('never waits indefinitely for compilation readiness', () async {
    marker.writeAsStringSync('{"state":"pending"}');
    expect(
      await waitForEarlyWorkerAot(
        marker.path,
        source.path,
        timeout: Duration.zero,
      ),
      isNull,
    );
  });
}
