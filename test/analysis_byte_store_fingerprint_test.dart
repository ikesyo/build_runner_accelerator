import 'dart:convert';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/analysis_byte_store_fingerprint.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
    'preserves persisted namespaces across chunk and SHA block boundaries',
    () {
      for (final length in [0, 1, 55, 56, 63, 64, 65, 127, 128, 129, 4096]) {
        final bytes = Uint8List.fromList([
          for (var i = 0; i < length; i++) (i * 37) % 256,
        ]);
        for (final experiments in [
          <String>[],
          ['a'],
          ['a', 'b'],
        ]) {
          for (final root in [
            '',
            'file:///cache/analyzer-14.3.0/',
            'file:///解析/',
          ]) {
            // The exact old on-disk namespace is a compatibility requirement.
            final old = sha256
                .convert([
                  ...bytes,
                  ...utf8.encode(experiments.join(' ')),
                  ...utf8.encode(root),
                ])
                .toString()
                .substring(0, 16);
            expect(
              analysisByteStoreFingerprint(
                bytes,
                experiments: experiments,
                analyzerRoot: root,
              ),
              old,
              reason:
                  'summary length=$length experiments=$experiments root=$root',
            );
          }
        }
      }
    },
  );
}
