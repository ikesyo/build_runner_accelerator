import 'dart:io';

import 'package:build_runner_accelerator/src/sdk_summary_lock.dart';

Future<void> main(List<String> args) async {
  final mode = args[0];
  final id = args[1];
  File('started-$id').writeAsStringSync('ready');
  if (mode == 'hold') {
    await sharedSdkSummaryPath(
      generate: () async {
        File('holding').writeAsStringSync('ready');
        while (true) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      },
    );
    return;
  }
  Future<String> generate() async {
    final summary = File('sdk.sum');
    if (!summary.existsSync() || summary.readAsStringSync() != 'valid') {
      final active = File('generating');
      active.createSync(exclusive: true);
      try {
        File(
          'generations',
        ).writeAsStringSync('generated\n', mode: FileMode.append);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        summary.writeAsStringSync('valid');
      } finally {
        active.deleteSync();
      }
    }
    return summary.absolute.path;
  }

  if (mode == 'local') {
    final results = await Future.wait(
      List.generate(4, (_) => sharedSdkSummaryPath(generate: generate)),
    );
    if (results.map((r) => r.path).toSet().length != 1) exit(2);
  } else if (mode == 'retry') {
    try {
      await sharedSdkSummaryPath(
        generate: () async => throw StateError('probe'),
      );
      exit(2);
    } on StateError {
      await sharedSdkSummaryPath(generate: generate);
    }
  } else {
    await sharedSdkSummaryPath(
      generate: generate,
      lockTimeout: mode == 'timeout'
          ? const Duration(milliseconds: 100)
          : const Duration(seconds: 5),
    );
  }
}
