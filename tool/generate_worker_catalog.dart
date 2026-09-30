import 'dart:io';
import 'package:build_runner_accelerator/src/manifest/catalog.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('usage: generate_worker_catalog <root> <worker-entrypoint>');
    exitCode = 1;
    return;
  }
  await generateWorkerCatalog(arguments[0], arguments[1]);
}
