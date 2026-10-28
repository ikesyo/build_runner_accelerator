import 'dart:io';
import 'dart:convert';
import 'package:build_runner_accelerator/src/manifest/settings.dart';
import 'package:build_runner_accelerator/src/manifest/catalog.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 || arguments.length > 4) {
    stderr.writeln(
      'usage: generate_worker_catalog <root> <worker-entrypoint> [settings-json] [workspace-json]',
    );
    exitCode = 1;
    return;
  }
  await generateWorkerCatalog(
    arguments[0],
    arguments[1],
    settings: BuildSettings.parse(
      arguments.length >= 3
          ? (jsonDecode(arguments[2]) as List).cast<String>()
          : [],
    ),
    buildWorkspace: arguments.length == 4
        ? jsonDecode(arguments[3]) as bool
        : false,
  );
}
