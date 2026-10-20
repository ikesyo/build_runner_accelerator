import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'source probe caches only complete results and reuses scoped kernels',
    () async {
      final temporary = await Directory.systemTemp.createTemp('probe-cache-');
      addTearDown(() => temporary.delete(recursive: true));
      final root = temporary.path;
      Directory('$root/lib').createSync();
      Directory('$root/.dart_tool').createSync();
      File(
        '$root/pubspec.yaml',
      ).writeAsStringSync('name: example\ndependencies:\n  build: any\n');
      final originalConfig = File('.dart_tool/package_config.json').absolute;
      final config = jsonDecode(originalConfig.readAsStringSync()) as Map;
      for (final entry in config['packages'] as List) {
        entry['rootUri'] = originalConfig.uri
            .resolve(entry['rootUri'] as String)
            .toString();
      }
      (config['packages'] as List).add({
        'name': 'example',
        'rootUri': Directory(root).uri.toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.11',
      });
      final packageConfig = File('$root/.dart_tool/package_config.json')
        ..writeAsStringSync(jsonEncode(config));
      final builder = File('$root/lib/builder.dart');
      final count = File('$root/count');
      final fail = File('$root/fail')..writeAsStringSync('');
      builder.writeAsStringSync("""import 'dart:io';
import 'package:build/build.dart';
Builder createBuilder(BuilderOptions options) {
  File(${jsonEncode(count.path)}).writeAsStringSync('called\\n', mode: FileMode.append);
  if (File(${jsonEncode(fail.path)}).existsSync()) throw StateError('factory cause');
  return Example();
}
class Example implements Builder {
  Map<String, List<String>> get buildExtensions => {'.dart': ['.g.dart']};
  Future<void> build(BuildStep step) async {}
}
""");
      final harness = File('$root/harness.dart')
        ..writeAsStringSync('''
import 'package:build_config/build_config.dart';
import 'package:build_runner_accelerator/src/manifest/model.dart';
import 'package:build_runner_accelerator/src/manifest/probe.dart';
Future<void> main(List<String> args) async {
  final config = BuildConfig.fromMap('example', const <String>[], {
    'builders': {'builder': {
      'import': 'package:example/builder.dart',
      'builder_factories': ['createBuilder'],
      'build_extensions': {'.dart': ['.g.dart']},
    }},
  });
  await probeFactoryMappings(args.single, [FactoryProbeRequest(
    id: 'selected', definition: DefinitionInfo.normal(config.builderDefinitions['example:builder']!),
    options: const {}, isRoot: true,
  )], cacheKey: 'same-settings');
}
''');
      final cache = Directory('$root/cache');
      Future<ProcessResult> run() => Process.run(
        Platform.resolvedExecutable,
        ['--packages=${packageConfig.path}', harness.path, root],
        environment: {
          'BUILD_RUNNER_ACCELERATOR_CACHE': cache.path,
          'BUILD_RUNNER_ACCELERATOR_METRICS': '1',
          'BUILD_RUNNER_ACCELERATOR_MANIFEST_WORKER_AOT': '',
        },
      );
      List<FileSystemEntity> responses() =>
          Directory('${cache.path}/probe').existsSync()
          ? Directory('${cache.path}/probe').listSync()
          : [];
      final failed = await run();
      expect(failed.exitCode, isNot(0));
      expect(failed.stderr, contains('factory cause'));
      expect(responses(), isEmpty);
      fail.deleteSync();
      final cold = await run();
      expect(cold.exitCode, 0, reason: '${cold.stderr}');
      expect(cold.stderr, contains('phase=compile'));
      expect(
        cold.stderr,
        contains('cache=hit'),
      ); // Failed factories can reuse compiled code.
      expect(cold.stderr, contains('phase=startup'));
      expect(cold.stderr, contains('phase=factory'));
      expect(responses(), hasLength(1));
      expect(count.readAsLinesSync(), hasLength(2));
      final warm = await run();
      expect(warm.exitCode, 0, reason: '${warm.stderr}');
      expect(
        count.readAsLinesSync(),
        hasLength(2),
      ); // Response hit runs no factory.
      responses().single.deleteSync();
      final helperHit = await run();
      expect(helperHit.exitCode, 0, reason: '${helperHit.stderr}');
      expect(helperHit.stderr, contains('cache=hit'));
      expect(count.readAsLinesSync(), hasLength(3));
      // Same settings fingerprint, changed mutable implementation: both caches miss.
      builder.writeAsStringSync(
        builder.readAsStringSync().replaceAll('.g.dart', '.new.dart'),
      );
      final changed = await run();
      expect(changed.exitCode, 0, reason: '${changed.stderr}');
      expect(changed.stderr, isNot(contains('cache=hit')));
      expect(responses(), hasLength(2));
      expect(count.readAsLinesSync(), hasLength(4));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
