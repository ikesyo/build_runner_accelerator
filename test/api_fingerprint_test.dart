import 'dart:io';

import 'package:build_runner_accelerator/src/api_fingerprint.dart';
import 'package:build_runner_accelerator/src/blake3.dart';
import 'package:build_runner_accelerator/src/indexed_blob_store.dart';
import 'package:test/test.dart';

const base = '''
import 'dart:async';

/// Greets the user by [name].
@Deprecated('use greet2')
String greet(String name, {int times = 1}) {
  final buffer = StringBuffer('hello');
  buffer.write(name);
  return buffer.toString();
}

const int answer = 42;

var inferred = 1;

final int typed = 1;

int _private() {
  return 1;
}

class Counter {
  /// The current count.
  int count = 0;

  void increment() {
    count += 1;
  }
}
''';

String fingerprintOf(String source) {
  final fingerprint = apiFingerprintForContent(source);
  if (fingerprint == null) {
    throw StateError('expected a fingerprint for: $source');
  }
  return fingerprint;
}

void main() {
  group('computeApiFingerprint', () {
    final baseFingerprint = fingerprintOf(base);

    void expectSame(String variant) {
      expect(
        fingerprintOf(variant),
        baseFingerprint,
        reason: 'fingerprint must not change',
      );
    }

    void expectDifferent(String variant) {
      expect(
        fingerprintOf(variant),
        isNot(baseFingerprint),
        reason: 'fingerprint must change',
      );
    }

    test('body-only edit to a method is invisible', () {
      expectSame(
        base.replaceAll('count += 1;', 'count += 1;\n    count += 0;'),
      );
    });

    test('body-only edit to a declared-type function is invisible', () {
      expectSame(
        base.replaceAll(
          "final buffer = StringBuffer('hello');",
          "final buffer = StringBuffer('hello!');",
        ),
      );
    });

    test('ordinary comment is invisible', () {
      expectSame(
        base.replaceAll(
          'const int answer = 42;',
          '// just a note\nconst int answer = 42;',
        ),
      );
    });

    test('offset shift is invisible', () {
      expectSame('\n$base');
    });

    test('typed final initializer value is invisible', () {
      expectSame(
        base.replaceAll('final int typed = 1;', 'final int typed = 2;'),
      );
    });

    test('declared-type private helper body value is invisible', () {
      expect(
        fingerprintOf('int _h() => 1;\nint f() => _h();'),
        fingerprintOf('int _h() => 2;\nint f() => _h();'),
      );
    });

    test('doc comment change is visible', () {
      expectDifferent(
        base.replaceAll(
          '/// Greets the user by [name].',
          '/// Greets the user warmly by [name].',
        ),
      );
    });

    test('doc comment moved between declarations is visible', () {
      expect(
        fingerprintOf('/// Docs\nclass A {}\nclass B {}'),
        isNot(fingerprintOf('class A {}\n/// Docs\nclass B {}')),
      );
    });

    test('doc comment moved between members is visible', () {
      expect(
        fingerprintOf('class A {\n  /// Docs\n  void m() {}\n  void n() {}\n}'),
        isNot(
          fingerprintOf(
            'class A {\n  void m() {}\n  /// Docs\n  void n() {}\n}',
          ),
        ),
      );
    });

    test('doc comment moved between parameters is visible', () {
      expect(
        fingerprintOf('void f(\n  /// Docs\n  int a,\n  int b,\n) {}'),
        isNot(fingerprintOf('void f(\n  int a,\n  /// Docs\n  int b,\n) {}')),
      );
    });

    test('parameter doc comment change is visible', () {
      expect(
        fingerprintOf('void f(\n  /// First\n  int a,\n) {}'),
        isNot(fingerprintOf('void f(\n  /// Second\n  int a,\n) {}')),
      );
    });

    test('type parameter doc comment change is visible', () {
      expect(
        fingerprintOf('class A<\n  /// Docs\n  T\n> {}'),
        isNot(fingerprintOf('class A<\n  /// Other\n  T\n> {}')),
      );
    });

    test('member doc comment change is visible', () {
      expectDifferent(
        base.replaceAll('/// The current count.', '/// The current total.'),
      );
    });

    test('API change is visible', () {
      expectDifferent(
        base.replaceAll('String greet(String name', 'String greet(Object name'),
      );
    });

    test('constant initializer change is visible', () {
      expectDifferent(
        base.replaceAll('const int answer = 42;', 'const int answer = 43;'),
      );
    });

    test('annotation change is visible', () {
      expectDifferent(
        base.replaceAll(
          "@Deprecated('use greet2')",
          "@Deprecated('use greet3')",
        ),
      );
    });

    test('parameter default change is visible', () {
      expectDifferent(base.replaceAll('{int times = 1}', '{int times = 2}'));
    });

    test('untyped variable initializer type change is visible', () {
      expectDifferent(
        base.replaceAll('var inferred = 1;', "var inferred = 'x';"),
      );
    });

    test('omitted return type body type change is visible', () {
      expect(fingerprintOf('f() => 1;'), isNot(fingerprintOf("f() => 'one';")));
    });

    test('omitted return type getter body type change is visible', () {
      expect(
        fingerprintOf('get x => 1;'),
        isNot(fingerprintOf("get x => 'one';")),
      );
    });

    test('method with omitted return type body change is visible', () {
      expect(
        fingerprintOf('class A { m() => 1; }'),
        isNot(fingerprintOf("class A { m() => 'one'; }")),
      );
    });

    test('member getter with omitted return type body change is visible', () {
      expect(
        fingerprintOf('class A { get x => 1; }'),
        isNot(fingerprintOf("class A { get x => 'one'; }")),
      );
    });

    test(
      'extension method with omitted return type body change is visible',
      () {
        expect(
          fingerprintOf('extension E on int { m() => 1; }'),
          isNot(fingerprintOf("extension E on int { m() => 'one'; }")),
        );
      },
    );

    test('private helper inferred type feeds the public API', () {
      expect(
        fingerprintOf('_h() => 1; f() => _h();'),
        isNot(fingerprintOf("_h() => 'one'; f() => _h();")),
      );
    });

    test('comment inside an omitted-type body stays invisible', () {
      expect(fingerprintOf('f() => 1;'), fingerprintOf('f() => /* note */ 1;'));
    });

    test('part unit fingerprint is computed and stable across body edits', () {
      final part = "part of 'lib.dart';\n\nint helper() { return 1; }";
      final edited = "part of 'lib.dart';\n\nint helper() { return 2; }";
      expect(fingerprintOf(part), fingerprintOf(edited));
    });

    test('augmentation declaration is unavailable', () {
      expect(
        apiFingerprintForContent('augment class A { augment void m() {} }'),
        isNull,
      );
    });

    test('import augment is unavailable', () {
      expect(
        apiFingerprintForContent(
          "import augment 'aug.dart';\nclass A { void m() {} }",
        ),
        isNull,
      );
    });

    test('augmentation library directive is unavailable', () {
      expect(
        apiFingerprintForContent("library augment 'main.dart';\nint f() => 1;"),
        isNull,
      );
    });

    test('syntax error is unavailable', () {
      expect(apiFingerprintForContent('class {'), isNull);
    });
  });

  group('ApiFingerprintCache', () {
    late Directory dir;
    late ApiFingerprintCache cache;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('api-fingerprint-');
      addTearDown(() => dir.deleteSync(recursive: true));
      cache = ApiFingerprintCache(
        store: IndexedBlobStore('${dir.path}/store.bin'),
      );
    });

    test('computes, stores and reuses by content digest', () {
      final digest = blake3Hex(base.codeUnits);
      expect(cache.contains(digest), isFalse);
      final fingerprint = cache.fingerprintFor(digest, base);
      expect(fingerprint, fingerprintOf(base));
      expect(cache.contains(digest), isTrue);
      expect(cache.lookup(digest), fingerprint);
      // A second call with different content under the same digest
      // returns the stored value: the digest is the key.
      expect(cache.fingerprintFor(digest, 'class Other {}'), fingerprint);
    });

    test('unavailable fingerprints are cached as markers', () {
      const broken = 'class {';
      final digest = blake3Hex(broken.codeUnits);
      expect(cache.fingerprintFor(digest, broken), isNull);
      expect(cache.contains(digest), isTrue);
      expect(cache.lookup(digest), isNull);
    });

    test('entries and markers survive reopening the store', () {
      final digest = blake3Hex(base.codeUnits);
      final fingerprint = cache.fingerprintFor(digest, base);
      const broken = 'class {';
      final brokenDigest = blake3Hex(broken.codeUnits);
      cache.fingerprintFor(brokenDigest, broken);

      final reopened = ApiFingerprintCache(
        store: IndexedBlobStore('${dir.path}/store.bin'),
      );
      expect(reopened.lookup(digest), fingerprint);
      expect(reopened.contains(brokenDigest), isTrue);
      expect(reopened.lookup(brokenDigest), isNull);
    });

    test('environment-caused nulls are not cached as markers', () {
      debugSetAstModelSupported(false);
      addTearDown(() => debugSetAstModelSupported(null));
      const source = 'int f() => 1;';
      final digest = blake3Hex(source.codeUnits);
      expect(cache.fingerprintFor(digest, source), isNull);
      expect(cache.contains(digest), isFalse);
    });
  });
}
