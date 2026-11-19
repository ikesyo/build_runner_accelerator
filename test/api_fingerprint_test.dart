import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
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
  final fingerprint = apiFingerprintForContent(source, package: 'app');
  if (fingerprint == null) {
    throw StateError('expected a fingerprint for: $source');
  }
  return fingerprint;
}

void main() {
  // Fingerprints are computed under the package's language version;
  // 'app' tracks the current SDK, 'old' is pinned to Dart 2.19.
  ApiFingerprintCache.packageLanguageVersions = {'app': '3.13', 'old': '2.19'};

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

    test('syntax newer than the package version is unavailable', () {
      // A record literal inside an explicitly typed function body:
      // invisible to the fingerprint at Dart 3, but a Dart 2.19
      // package does not parse it at all, so no fingerprint may be
      // computed for that package (the real build would fail).
      const source = '''
int typed() {
  final point = (1, 2);
  return point.\$1;
}
''';
      expect(apiFingerprintForContent(source, package: 'old'), isNull);
      expect(apiFingerprintForContent(source, package: 'app'), isNotNull);
      // The same content under two package versions fingerprints
      // differently: the effective version is a component.
      expect(
        apiFingerprintForContent(base, package: 'old'),
        isNot(apiFingerprintForContent(base, package: 'app')),
      );
    });

    test('const primary constructor field values are visible', () {
      // The analyzer signature misses these initializers: it only
      // hashes field initializers when it finds a traditional const
      // constructor. The values are observable through constant
      // evaluation, so the fingerprint must cover them itself.
      expect(
        fingerprintOf('class const A() { final int x = 1; }'),
        isNot(fingerprintOf('class const A() { final int x = 2; }')),
      );
      // A non-const primary constructor exposes no constant value,
      // so its initializers stay invisible, like the signature's.
      expect(
        fingerprintOf('class A() { final int x = 1; }'),
        fingerprintOf('class A() { final int x = 2; }'),
      );
      // Type parameter bounds sit between the class name and the
      // parameter list; the detection must skip them.
      expect(
        fingerprintOf('class const A<T extends Object>() { final int x = 1; }'),
        isNot(
          fingerprintOf(
            'class const A<T extends Object>() { final int x = 2; }',
          ),
        ),
      );
    });

    test('language version override is visible', () {
      expect(
        fingerprintOf('// @dart = 3.0\n$base'),
        isNot(fingerprintOf('// @dart = 3.1\n$base')),
        reason: 'fingerprint must change with the override',
      );
      expect(
        fingerprintOf('// @dart = 3.1\n$base'),
        isNot(baseFingerprint),
        reason: 'an override must differ from no override',
      );
      // The package 'app' is pinned to 3.13, so this override names
      // the version already in effect; its presence alone is
      // observable through the element model and must still change
      // the fingerprint.
      expect(
        fingerprintOf('// @dart = 3.13\n$base'),
        isNot(baseFingerprint),
        reason: 'an override matching the package version must differ',
      );
    });

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

    test('doc line moved between documented declarations is visible', () {
      expect(
        fingerprintOf('/// A\n/// B\nclass A {}\n/// C\nclass B {}'),
        isNot(fingerprintOf('/// A\nclass A {}\n/// B\n/// C\nclass B {}')),
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
        apiFingerprintForContent(
          'augment class A { augment void m() {} }',
          package: 'app',
        ),
        isNull,
      );
    });

    test('import augment is unavailable', () {
      expect(
        apiFingerprintForContent(
          "import augment 'aug.dart';\nclass A { void m() {} }",
          package: 'app',
        ),
        isNull,
      );
    });

    test('augmentation library directive is unavailable', () {
      expect(
        apiFingerprintForContent(
          "library augment 'main.dart';\nint f() => 1;",
          package: 'app',
        ),
        isNull,
      );
    });

    test('syntax error is unavailable', () {
      expect(apiFingerprintForContent('class {', package: 'app'), isNull);
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
      expect(cache.contains(digest, package: 'app'), isFalse);
      final fingerprint = cache.fingerprintFor(digest, base, package: 'app');
      expect(fingerprint, fingerprintOf(base));
      expect(cache.contains(digest, package: 'app'), isTrue);
      expect(cache.lookup(digest, package: 'app'), fingerprint);
      // A second call with different content under the same digest
      // returns the stored value: the digest is the key.
      expect(
        cache.fingerprintFor(digest, 'class Other {}', package: 'app'),
        fingerprint,
      );
    });

    test('entries are keyed by package language version', () {
      final digest = blake3Hex(base.codeUnits);
      final current = cache.fingerprintFor(digest, base, package: 'app');
      final old = cache.fingerprintFor(digest, base, package: 'old');
      expect(old, isNot(current));
      expect(cache.lookup(digest, package: 'app'), current);
      expect(cache.lookup(digest, package: 'old'), old);
      // A package whose version was never recorded gets nothing.
      expect(cache.fingerprintFor(digest, base, package: 'unknown'), isNull);
      expect(cache.contains(digest, package: 'unknown'), isFalse);
    });

    test('unavailable fingerprints are cached as markers', () {
      const broken = 'class {';
      final digest = blake3Hex(broken.codeUnits);
      expect(cache.fingerprintFor(digest, broken, package: 'app'), isNull);
      expect(cache.contains(digest, package: 'app'), isTrue);
      expect(cache.lookup(digest, package: 'app'), isNull);
    });

    test('entries and markers survive reopening the store', () {
      final digest = blake3Hex(base.codeUnits);
      final fingerprint = cache.fingerprintFor(digest, base, package: 'app');
      const broken = 'class {';
      final brokenDigest = blake3Hex(broken.codeUnits);
      cache.fingerprintFor(brokenDigest, broken, package: 'app');

      final reopened = ApiFingerprintCache(
        store: IndexedBlobStore('${dir.path}/store.bin'),
      );
      expect(reopened.lookup(digest, package: 'app'), fingerprint);
      expect(reopened.contains(brokenDigest, package: 'app'), isTrue);
      expect(reopened.lookup(brokenDigest, package: 'app'), isNull);
    });

    test('fingerprintForParse reuses the caller parse and stores', () {
      final digest = blake3Hex(base.codeUnits);
      final parsed = parseString(
        content: base,
        featureSet: apiFingerprintFeatureSet('app'),
      );
      final fingerprint = cache.fingerprintForParse(
        digest,
        parsed,
        package: 'app',
      );
      expect(fingerprint, fingerprintOf(base));
      expect(cache.lookup(digest, package: 'app'), fingerprint);
    });

    test('fingerprintForParse stores unavailable markers', () {
      const source = 'augment class A { augment void m() {} }';
      final digest = blake3Hex(source.codeUnits);
      final parsed = parseString(content: source, throwIfDiagnostics: false);
      expect(cache.fingerprintForParse(digest, parsed, package: 'app'), isNull);
      expect(cache.contains(digest, package: 'app'), isTrue);
      expect(cache.lookup(digest, package: 'app'), isNull);
    });

    test('a disabled AST model bypasses stored fingerprints', () {
      final digest = blake3Hex(base.codeUnits);
      expect(cache.fingerprintFor(digest, base, package: 'app'), isNotNull);

      debugSetAstModelSupported(false);
      addTearDown(() => debugSetAstModelSupported(null));
      expect(cache.fingerprintFor(digest, base, package: 'app'), isNull);
    });

    test('environment-caused nulls are not cached as markers', () {
      debugSetAstModelSupported(false);
      addTearDown(() => debugSetAstModelSupported(null));
      const source = 'int f() => 1;';
      final digest = blake3Hex(source.codeUnits);
      expect(cache.fingerprintFor(digest, source, package: 'app'), isNull);
      expect(cache.contains(digest, package: 'app'), isFalse);
    });
  });

  group('shared store namespace', () {
    tearDown(() => ApiFingerprintCache.sharedAnalyzerRoot = null);

    test('is SDK-only until the analyzer root is known', () {
      ApiFingerprintCache.sharedAnalyzerRoot = null;
      final sdk = Platform.version.split(' ').first;
      expect(debugApiFingerprintStoreNamespace(), 'v5-$sdk');
    });

    test('carries the analyzer package directory once known', () {
      ApiFingerprintCache.sharedAnalyzerRoot =
          'file:///home/user/.pub-cache/hosted/pub.dev/analyzer-14.6.0/';
      final sdk = Platform.version.split(' ').first;
      expect(
        debugApiFingerprintStoreNamespace(),
        startsWith('v5-$sdk-analyzer-14.6.0-'),
      );
    });

    test('separates installs that share a directory name', () {
      final sdk = Platform.version.split(' ').first;
      ApiFingerprintCache.sharedAnalyzerRoot = 'file:///checkout-a/analyzer/';
      final a = debugApiFingerprintStoreNamespace();
      ApiFingerprintCache.sharedAnalyzerRoot = 'file:///checkout-b/analyzer/';
      final b = debugApiFingerprintStoreNamespace();
      expect(a, startsWith('v5-$sdk-analyzer-'));
      expect(b, startsWith('v5-$sdk-analyzer-'));
      expect(a, isNot(b));
    });
  });
}
