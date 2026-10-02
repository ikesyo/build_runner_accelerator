import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/indexed_blob_store.dart';

Future<void> main(List<String> args) async {
  final store = IndexedBlobStore(args[0]);
  // All processes index the empty file before any process starts writing.
  store.get('prime');
  stdout.writeln('ready');
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  try {
    for (var round = 0; round < 32; round++) {
      final value = Uint8List.fromList([round]);
      for (final key in [
        'shared-$round.resolved',
        'worker-${args[1]}-$round',
      ]) {
        var stored = false;
        for (var retry = 0; retry < 1000 && !stored; retry++) {
          stored = store.put(key, value);
          if (!stored)
            await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        if (!stored) throw StateError('could not cache $key');
      }
    }
  } finally {
    store.close();
  }
}
