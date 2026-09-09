import 'dart:io';

import 'package:build_runner_accelerator/launcher.dart';

Future<void> main(List<String> arguments) async {
  try {
    exitCode = await runLauncher(arguments);
  } on Object catch (error, stackTrace) {
    stderr.writeln('build_runner_accelerator: $error');
    if (Platform.environment['BUILD_RUNNER_ACCELERATOR_DEBUG'] == '1') {
      stderr.writeln(stackTrace);
    }
    exitCode = 1;
  }
}
