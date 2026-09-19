import 'package:build_runner_accelerator/src/manifest/source.dart';
import 'package:test/test.dart';

void main() {
  group('dartSourceString', () {
    test('escapes Dart string syntax characters', () {
      const input = r"quote' slash\ dollar$";

      expect(dartSourceString(input), r"'quote\' slash\\ dollar\$'");
    });

    test('escapes control characters and line separators', () {
      const input = '\u0000\u0008\u001f\u007f\u2028\u2029';

      expect(
        dartSourceString(input),
        r"'\u0000\u0008\u001f\u007f\u2028\u2029'",
      );
    });

    test('preserves printable Unicode characters', () {
      expect(
        dartSourceString('package:example/日本語/😀'),
        "'package:example/日本語/😀'",
      );
    });
  });
}
