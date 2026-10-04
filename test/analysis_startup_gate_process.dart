import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/analysis_startup_gate.dart';
import 'package:build_runner_accelerator/src/packed_analysis_byte_store.dart';

Future<void> main(List<String> args) async {
  final dir = args[0];
  final store = PackedAnalysisByteStore(dir);
  // Deliberately index the empty pack before the owner writes to it.
  store.get('library.linked');
  final gate = AnalysisStartupGate(
    '$dir/.analysis-startup.lock',
    isWarm: () => store.hasLinkedEntries,
  );
  final commands = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  stdout.writeln('ready');
  AnalysisStartupLease? lease;
  try {
    await for (final command in commands) {
      switch (command) {
        case 'acquire':
          stdout.writeln('waiting');
          lease = await gate.acquire(
            timeout: args.contains('timeout')
                ? const Duration(milliseconds: 100)
                : const Duration(seconds: 30),
          );
          stdout.writeln(lease == null ? 'warm' : 'owner');
        case 'write':
          store.putGet('library.linked', Uint8List.fromList([42]));
          stdout.writeln('written');
        case 'read':
          stdout.writeln(
            store.get('library.linked')?.single == 42 ? 'hit' : 'miss',
          );
        case 'release':
          lease?.release();
          lease = null;
          stdout.writeln('released');
      }
    }
  } finally {
    lease?.release();
    store.close();
  }
}
