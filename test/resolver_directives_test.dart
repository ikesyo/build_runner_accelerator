import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:build_runner_accelerator/src/resolver_directives.dart';
import 'package:test/test.dart';

void main() {
  test('directive-only parsing preserves full-unit conditional URI recovery', () {
    final sources = <String>[
      "import 'base.dart' if /* comment */ (dart.library.io) 'io.dart' "
          "if (dart.library.html) 'html.dart'; class A { void f() { if (true) {} } }",
      "// @dart = 3.11\n@deprecated library; "
          "export 'semi;colon.dart' if (dart.library.io) 'semi;io.dart';",
      "import r'base.dart' if (dart.library.io) r'io.dart'; "
          "final text = '''import 'noise.dart' if (dart.library.io) 'noise_io.dart';''';",
      "class A {} import 'late.dart' if (dart.library.io) 'late_io.dart';",
      "final a = 1; export 'late.dart' if (dart.library.html) 'late_html.dart';",
      "import 'base.dart' if (dart.library.io) 'io.dart' class A {}",
      "import 'base.dart' if (dart.library.io 'io.dart'; class A {}",
      "import 'base.dart' if (dart.library.io) 'io.dart'; /* unterminated",
      "import 'base.dart' if (dart.library.io) 'io.dart'; final text = 'unterminated",
      "part of 'parent.dart'; export 'base.dart' if (dart.library.io) 'io.dart';",
      "/// import 'comment.dart' if (dart.library.io) 'comment_io.dart';\nclass A {}",
      "@deprecated class A {} import 'late.dart' if (dart.library.io) 'io.dart';",
      '',
    ];
    for (final source in sources) {
      expect(
        _conditionalUris(parseResolverDirectives(source)),
        _conditionalUris(
          parseString(
            content: source,
            throwIfDiagnostics: false,
          ).unit.directives,
        ),
        reason: source,
      );
    }
  });
}

List<String?> _conditionalUris(Iterable<Directive> directives) => [
  for (final directive in directives)
    if (directive is NamespaceDirective &&
        directive.configurations.isNotEmpty) ...[
      directive.uri.stringValue,
      for (final configuration in directive.configurations)
        configuration.uri.stringValue,
    ],
];
