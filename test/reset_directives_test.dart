import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:build_runner/src/build/asset_content.dart';
import 'package:build_runner_accelerator/src/reset_directives.dart';
import 'package:test/test.dart';

final legacy = RegExp(
  r'''^\s*(?:import|export|part(?:\s+of)?|library)\s[^;]*;''',
  multiLine: true,
);
Set<String> reference(String content) =>
    legacy.allMatches(content).map((match) => match.group(0)!.trim()).toSet();

void main() {
  test(
    'exact legacy extraction and guarded reuse, including malformed and late text',
    () {
      final cases = [
        '',
        "import 'a.dart';\nclass A {}",
        "// @dart=3.11\nlibrary example;\npart 'a.dart';\npart of example;",
        "import\n 'a.dart'\n if (dart.library.io) 'b.dart';\nexport 'c.dart' show C;",
        "/* comment */\nimport 'a.dart';\n// import 'ignored.dart';",
        "class A {}\nimport 'late.dart';\npart of 'parent.dart';",
        "final text = '''\nimport 'string.dart';\n''';\n/*\nexport 'comment.dart';\n*/",
        "import 'unterminated\npart 'later.dart';",
        "\r\n\t library foo;\u2028part of foo;\u2029export 'x.dart';",
        "import 'a; b.dart';\npart\nof foo;\nimport'';",
        'library;\npart of;\nlibrary example\nclass A {}',
      ];
      void verify(String content) {
        final current = ResetDirectiveContent(content);
        expect(current.directives, reference(content), reason: content);
        final copy = utf8.decode(utf8.encode(content));
        final old = current.reuse(copy)!;
        expect(old.directives, reference(copy));
        expect(identical(old.directives, current.directives), true);
        expect(identical(old.content, copy), true);
        expect(
          () => old.directives.add("export 'stale.dart';"),
          throwsUnsupportedError,
        );
      }

      for (final content in cases) {
        verify(content);
      }
      final random = Random(92);
      for (var i = 0; i < 300; i++) {
        verify(
          List.generate(
            1 + random.nextInt(8),
            (_) => cases[random.nextInt(cases.length)],
          ).join(random.nextBool() ? '\n' : ' '),
        );
      }
    },
  );

  test(
    'whole immutable text, not mutable bytes or an inherited digest, authorizes reuse',
    () {
      final bytes = Uint8List.fromList(utf8.encode("import 'a.dart';"));
      final first = AssetContent.bytes(bytes);
      final digest = first.digest;
      final version = ResetDirectiveContent(first.stringValue());
      bytes[8] = 'b'.codeUnitAt(0);
      final changed = AssetContent.bytes(bytes, digest: digest);
      expect(changed.digest, digest);
      expect(version.reuse(changed.stringValue()), isNull);
      expect(ResetDirectiveContent(changed.stringValue()).directives, {
        "import 'b.dart';",
      });
      expect(version.directives, {"import 'a.dart';"});
    },
  );

  test(
    'body-only, directive and late-directive edits fall back to full extraction',
    () {
      final first = ResetDirectiveContent("part of app;\nclass A {}");
      for (final content in [
        "part of app;\nclass B {}",
        "part of other;\nclass A {}",
        "part of app;\nclass A {}\nimport 'late.dart';",
        "part of app;\nclass A {}\n// @dart=3.11",
      ]) {
        expect(first.reuse(content), isNull);
        expect(ResetDirectiveContent(content).directives, reference(content));
      }
      expect(
        ResetDirectiveContent("part of app;\nclass B {}").directives,
        first.directives,
      );
      final large = "part of app;\n${'class A {}\n' * 10000}";
      final version = ResetDirectiveContent(large);
      expect(version.reuse('$large '), isNull);
      expect(
        version.reuse(utf8.decode(utf8.encode(large)))!.directives,
        version.directives,
      );
    },
  );
}
