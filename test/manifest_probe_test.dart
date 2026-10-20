import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_config/build_config.dart';
import 'package:build_runner_accelerator/src/manifest/model.dart';
import 'package:build_runner_accelerator/src/manifest/probe.dart';
import 'package:test/test.dart';

void main() {
  test('decodes valid mappings and ignores invalid partial results', () {
    final config = _config();
    final requests = <FactoryProbeRequest>[
      _request(config, 'valid'),
      _request(config, 'wrong_factory'),
      _request(config, 'wrong_shape'),
    ];

    final result = decodeFactoryProbeResponse(
      jsonEncode({
        'valid': [
          {
            'factory': 'createBuilder',
            'build_extensions': {
              '.dart': ['.g.dart'],
            },
          },
        ],
        'wrong_factory': [
          {
            'factory': 'otherFactory',
            'build_extensions': {
              '.dart': ['.g.dart'],
            },
          },
        ],
        'wrong_shape': <Object>[],
        'unknown': [
          {
            'factory': 'createBuilder',
            'build_extensions': <String, List<String>>{},
          },
        ],
      }),
      requests,
    );

    expect(result.keys, <String>['valid']);
    expect(result['valid']!.single.factory, 'createBuilder');
    expect(result['valid']!.single.buildExtensions, {
      '.dart': <String>['.g.dart'],
    });
  });

  test('treats invalid or non-object probe responses as unavailable', () {
    final request = _request(_config(), 'builder');

    expect(
      decodeFactoryProbeResponse('not json', <FactoryProbeRequest>[request]),
      isEmpty,
    );
    expect(
      decodeFactoryProbeResult(<Object>[], <FactoryProbeRequest>[request]),
      isEmpty,
    );
  });

  group('factory probe transport', () {
    late Directory temporary;
    late File result;
    final requests = [_request(_config(), 'selected')];
    setUp(() {
      temporary = Directory.systemTemp.createTempSync('probe-transport-');
      result = File('${temporary.path}/result.json');
    });
    tearDown(() => temporary.deleteSync(recursive: true));

    Future<String> run(String source, {Duration? timeout}) async {
      final script = File('${temporary.path}/child.dart')
        ..writeAsStringSync(source);
      return runFactoryProbeProcess(
        Platform.resolvedExecutable,
        [script.path, result.path],
        root: temporary.path,
        result: result,
        requests: requests,
        timeout: timeout ?? const Duration(seconds: 10),
      );
    }

    TypeMatcher<FactoryProbeFailure> fails(String kind) =>
        isA<FactoryProbeFailure>()
            .having((error) => error.kind, 'kind', kind)
            .having(
              (error) => error.toString(),
              'builder and factory',
              contains('example:builder: createBuilder'),
            );

    test('reports start failure', () async {
      await expectLater(
        runFactoryProbeProcess(
          '${temporary.path}/absent',
          [],
          root: temporary.path,
          result: result,
          requests: requests,
        ),
        throwsA(fails('start failure')),
      );
    });
    test('drains saturated pipes and bounds stderr on nonzero exit', () async {
      await expectLater(
        run('''import 'dart:io';
void main(List<String> args) {
  for (var i = 0; i < 5000; i++) {
    stdout.writeln('stdout output to fill the pipe');
    stderr.writeln('stderr output to fill the pipe');
  }
  stderr.writeln('original factory cause');
  exitCode = 7;
}
'''),
        throwsA(
          fails('nonzero exit')
              .having(
                (error) => error.stderrTail.length,
                'bounded stderr',
                lessThanOrEqualTo(8192),
              )
              .having(
                (error) => error.stderrTail,
                'original cause',
                contains('original factory cause'),
              ),
        ),
      );
    });
    test('reports missing result and ignores stale file', () async {
      result.writeAsStringSync('{}');
      await expectLater(
        run('void main() {}'),
        throwsA(fails('missing result')),
      );
    });
    test('rejects malformed and incomplete responses', () async {
      for (final response in ['not json', '[]', '{}']) {
        await expectLater(
          run(
            "import 'dart:io'; void main(List<String> a) { File(a.single).writeAsStringSync(${jsonEncode(response)}); }",
          ),
          throwsA(fails('malformed response')),
        );
      }
    });
    test('reports timeout without accepting an early result', () async {
      await expectLater(
        run('''import 'dart:io'; import 'dart:async';
void main(List<String> args) {
  File(args.single).writeAsStringSync('{}');
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
''', timeout: const Duration(milliseconds: 300)),
        throwsA(fails('timeout')),
      );
    });
    test('valid unsupported extension shapes are transport successes', () async {
      final response = jsonEncode({
        'selected': [
          {
            'factory': 'createBuilder',
            'build_extensions': {
              'unsupported*': ['anything*'],
            },
          },
        ],
      });
      expect(
        await run(
          "import 'dart:io'; void main(List<String> a) { File(a.single).writeAsStringSync(${jsonEncode(response)}); }",
        ),
        response,
      );
    });
  });

  group('compiled source helper', () {
    late Directory temporary;
    late File source;
    late File kernel;
    late File cached;
    final requests = [_request(_config(), 'selected')];
    final packageConfig = File('.dart_tool/package_config.json').absolute.path;
    setUp(() {
      temporary = Directory.systemTemp.createTempSync('probe-kernel-');
      source = File('${temporary.path}/probe.dart');
      kernel = File('${temporary.path}/probe.dill');
      cached = File('${temporary.path}/cache/probe.dill');
    });
    tearDown(() => temporary.deleteSync(recursive: true));

    Future<void> compile({Duration? timeout}) => compileFactoryProbeKernel(
      root: temporary.path,
      packageConfig: packageConfig,
      source: source,
      kernel: kernel,
      cachedKernel: cached,
      requests: requests,
      timeout: timeout ?? const Duration(seconds: 20),
    );

    test(
      'cold compile and warm helper reuse execute identical mappings',
      () async {
        final response = jsonEncode({
          'selected': [
            {
              'factory': 'createBuilder',
              'build_extensions': {
                '.dart': ['.g.dart'],
              },
            },
          ],
        });
        source.writeAsStringSync("""import 'dart:io';
void main(List<String> args) {
  File(args[1]).writeAsStringSync('ready');
  File(args[0]).writeAsStringSync(${jsonEncode(response)});
}
""");
        Future<String> run() => runFactoryProbeProcess(
          Platform.resolvedExecutable,
          [
            kernel.path,
            '${temporary.path}/result.json',
            '${temporary.path}/ready',
          ],
          root: temporary.path,
          result: File('${temporary.path}/result.json'),
          requests: requests,
          started: File('${temporary.path}/ready'),
        );
        await compile();
        expect(await run(), response);
        final bytes = cached.readAsBytesSync();
        source.deleteSync(); // A warm hit must not invoke the compiler.
        kernel.deleteSync();
        await compile();
        expect(kernel.readAsBytesSync(), bytes);
        expect(await run(), response);
      },
    );

    test('compile errors retain context and never publish a helper', () async {
      source.writeAsStringSync('invalid Dart source');
      await expectLater(
        compile(),
        throwsA(
          isA<FactoryProbeFailure>()
              .having((e) => e.kind, 'kind', 'nonzero exit')
              .having((e) => e.reason, 'phase', contains('compile'))
              .having((e) => e.stderrTail, 'compiler error', isNotEmpty)
              .having((e) => e.context, 'context', contains('createBuilder')),
        ),
      );
      expect(cached.existsSync(), isFalse);
    });

    test('compile timeout never publishes a helper', () async {
      source.writeAsStringSync('void main() {}');
      await expectLater(
        compile(timeout: const Duration(milliseconds: 1)),
        throwsA(
          isA<FactoryProbeFailure>().having((e) => e.kind, 'kind', 'timeout'),
        ),
      );
      expect(cached.existsSync(), isFalse);
    });

    test('startup has a separate budget from factory execution', () async {
      source.writeAsStringSync("""import 'dart:io'; import 'dart:async';
Future<void> main(List<String> args) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  File(args[1]).writeAsStringSync('ready');
  File(args[0]).writeAsStringSync('invalid response');
}
""");
      await compile();
      await expectLater(
        runFactoryProbeProcess(
          Platform.resolvedExecutable,
          [kernel.path, '${temporary.path}/result', '${temporary.path}/ready'],
          root: temporary.path,
          result: File('${temporary.path}/result'),
          requests: requests,
          started: File('${temporary.path}/ready'),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<FactoryProbeFailure>().having(
            (e) => e.kind,
            'kind',
            'malformed response',
          ),
        ),
      );
    });

    test(
      'startup and factory timeouts reject even an existing result',
      () async {
        source.writeAsStringSync("""import 'dart:io'; import 'dart:async';
void main(List<String> args) {
  if (args.length > 2) File(args[1]).writeAsStringSync('ready');
  File(args[0]).writeAsStringSync('{}');
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
""");
        await compile();
        for (final factory in [false, true]) {
          await expectLater(
            runFactoryProbeProcess(
              Platform.resolvedExecutable,
              [
                kernel.path,
                '${temporary.path}/result',
                '${temporary.path}/ready',
                if (factory) 'factory',
              ],
              root: temporary.path,
              result: File('${temporary.path}/result'),
              requests: requests,
              started: File('${temporary.path}/ready'),
              startupTimeout: factory
                  ? const Duration(seconds: 10)
                  : const Duration(milliseconds: 100),
              timeout: const Duration(milliseconds: 100),
            ),
            throwsA(
              isA<FactoryProbeFailure>()
                  .having((e) => e.kind, 'kind', 'timeout')
                  .having(
                    (e) => e.reason,
                    'phase',
                    contains(
                      factory
                          ? 'factory: deadline exceeded'
                          : 'startup: deadline exceeded',
                    ),
                  ),
            ),
          );
        }
      },
    );
  });

  test('escalates a probe that ignores graceful termination', () async {
    final exitCode = Completer<int>();
    final signals = <String>[];
    final result = await waitForProbeExit(
      exitCode: exitCode.future,
      kill: () => signals.add('term'),
      forceKill: () {
        signals.add('kill');
        exitCode.complete(-9);
      },
      timeout: const Duration(milliseconds: 20),
      killGracePeriod: const Duration(milliseconds: 1),
    );
    expect(result, isNull);
    expect(signals, ['term', 'kill']);
  });

  test('kills a probe that exceeds its timeout', () async {
    final exitCode = Completer<int>();
    var killed = false;

    final result = await waitForProbeExit(
      exitCode: exitCode.future,
      kill: () => killed = true,
      timeout: const Duration(milliseconds: 20),
      killGracePeriod: const Duration(milliseconds: 1),
    );

    expect(result, isNull);
    expect(killed, isTrue);
  });
}

BuildConfig _config() => BuildConfig.fromMap('example', const <String>[], {
  'builders': {
    'builder': {
      'import': 'package:example/builder.dart',
      'builder_factories': <String>['createBuilder'],
      'build_extensions': <String, List<String>>{
        '.dart': <String>['.g.dart'],
      },
    },
  },
});

FactoryProbeRequest _request(BuildConfig config, String id) =>
    FactoryProbeRequest(
      id: id,
      definition: DefinitionInfo.normal(
        config.builderDefinitions['example:builder']!,
      ),
      options: const <String, dynamic>{},
      isRoot: true,
    );
