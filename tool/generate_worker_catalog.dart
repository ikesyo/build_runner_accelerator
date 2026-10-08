import 'dart:io';
import 'dart:convert';
import 'package:build_runner_accelerator/src/manifest/settings.dart';
import 'package:build_runner_accelerator/src/manifest/catalog.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 || arguments.length > 3) {
    stderr.writeln('usage: generate_worker_catalog <root> <worker-entrypoint>');
    exitCode = 1;
    return;
  }
  await generateWorkerCatalog(
    arguments[0],
    arguments[1],
    settings: BuildSettings.parse(
      arguments.length == 3
          ? (jsonDecode(arguments[2]) as List).cast<String>()
          : [],
    ),
  );
}
