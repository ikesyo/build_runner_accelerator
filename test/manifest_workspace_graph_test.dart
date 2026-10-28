import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:build_runner_accelerator/src/manifest/package_graph.dart';
import 'package:build_runner_accelerator/src/manifest/catalog.dart';
import 'package:build_runner_accelerator/src/manifest/settings.dart';
import 'package:build_runner_accelerator/src/worker.dart' show runWorker;
import 'package:build_runner/src/build_plan/build_packages.dart' as stock;
import 'package:build_runner/src/build_plan/build_paths.dart' as stock;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'accelerator-workspace-graph-',
    );
    final packages = {
      'root': 'name: root\nworkspace: [member]\ndependencies:\n  dep: any\n',
      'member':
          'name: member\nresolution: workspace\ndev_dependencies:\n  generator: any\n',
      'dep': 'name: dep\ndev_dependencies:\n  ignored: any\n',
      'generator': 'name: generator\n',
    };
    for (final entry in packages.entries) {
      final directory = entry.key == 'root'
          ? root
          : Directory(p.join(root.path, entry.key));
      await directory.create(recursive: true);
      await File(
        p.join(directory.path, 'pubspec.yaml'),
      ).writeAsString(entry.value);
    }
    await File(
      p.join(root.path, 'pubspec.lock'),
    ).writeAsString('packages: {}\n');
    final dartTool = Directory(p.join(root.path, '.dart_tool'));
    await dartTool.create();
    await File(p.join(dartTool.path, 'package_config.json')).writeAsString(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final name in packages.keys)
            {
              'name': name,
              'rootUri': name == 'root' ? '../' : '../$name/',
              'packageUri': 'lib/',
            },
        ],
      }),
    );
    await File(p.join(dartTool.path, 'package_graph.json')).writeAsString(
      jsonEncode({
        'roots': ['root', 'member'],
        'packages': [],
      }),
    );
    for (final entry in {'root': '../..', 'member': '../../..'}.entries) {
      final directory = entry.key == 'root'
          ? root.path
          : p.join(root.path, entry.key);
      final pubDir = Directory(p.join(directory, '.dart_tool', 'pub'));
      await pubDir.create(recursive: true);
      await File(
        p.join(pubDir.path, 'workspace_ref.json'),
      ).writeAsString(jsonEncode({'workspaceRoot': entry.value}));
    }
  });
  tearDown(() async => root.delete(recursive: true));

  test('workspace roots include member dev dependencies', () async {
    final graph = await loadPackageGraph(root.path, buildWorkspace: true);
    final reference = await stock.BuildPackages.forPaths(
      stock.BuildPaths(
        packagePath: root.path,
        workspacePath: root.path,
        buildWorkspace: true,
      ),
    );
    expect(graph.allPackages['root']!.isRoot, isTrue);
    expect(graph.allPackages['member']!.isRoot, isTrue);
    expect(graph.allPackages['dep']!.isRoot, isFalse);
    expect(graph.allPackages['member']!.dependencies.map((d) => d.name), [
      'generator',
    ]);
    expect(graph.allPackages['dep']!.dependencies, isEmpty);
    for (final package in graph.allPackages.values) {
      expect(package.isRoot, reference[package.name]!.isOutput);
      expect(
        package.dependencies.map((dependency) => dependency.name),
        unorderedEquals(reference[package.name]!.dependencies),
        reason: package.name,
      );
    }
  });

  test('single package graph ignores member dev dependencies', () async {
    final graph = await loadPackageGraph(root.path);
    expect(graph.allPackages['member']!.isRoot, isFalse);
    expect(graph.allPackages['member']!.dependencies, isEmpty);
  });

  test('workspace paths agree with stock from root and member', () {
    for (final directory in [root.path, p.join(root.path, 'member')]) {
      final paths = manifestBuildPaths(directory, buildWorkspace: true);
      final reference = stock.BuildPaths.load(directory, buildWorkspace: true);
      expect(paths.root, reference.outputRootPath);
      expect(paths.buildWorkspace, reference.buildWorkspace);
      expect(paths.currentPackage, directory == root.path ? 'root' : 'member');
    }
  });

  test('workspace request outside a workspace uses the current package', () {
    final directory = p.join(root.path, 'dep');
    final paths = manifestBuildPaths(directory, buildWorkspace: true);
    expect(paths.root, directory);
    expect(paths.currentPackage, 'dep');
    expect(paths.buildWorkspace, isFalse);
  });

  test('stale workspace reference is ignored', () async {
    final directory = p.join(root.path, 'member');
    await File(
      p.join(directory, 'pubspec.yaml'),
    ).writeAsString('name: member\n');
    final paths = manifestBuildPaths(directory, buildWorkspace: true);
    expect(paths.root, directory);
    expect(paths.buildWorkspace, isFalse);
  });

  test('member-relative define aliases use the current package', () async {
    final settings = BuildSettings.parse([
      '--define',
      ':example=mode=one',
      '--define',
      'member:example=mode=two',
    ]);
    expect(
      () => generateWorkerCatalog(
        p.join(root.path, 'member'),
        p.join(root.path, 'worker.dart'),
        settings: settings,
        buildWorkspace: true,
      ),
      throwsArgumentError,
    );
  });

  test(
    'early catalog includes a builder used only by a workspace member',
    () async {
      await File(p.join(root.path, 'generator', 'build.yaml')).writeAsString('''
builders:
  example:
    import: "package:generator/builder.dart"
    builder_factories: ["example"]
    build_extensions: {".txt": [".out"]}
    auto_apply: root_package
    build_to: source
''');
      final worker = p.join(root.path, 'worker.dart');
      await generateWorkerCatalog(
        p.join(root.path, 'member'),
        worker,
        buildWorkspace: true,
      );
      expect(
        await File(worker).readAsString(),
        contains('package:generator/builder.dart'),
      );
    },
  );

  test('workspace graph cannot silently omit an unknown root', () async {
    await File(
      p.join(root.path, '.dart_tool', 'package_graph.json'),
    ).writeAsString(
      jsonEncode({
        'roots': ['root', 'missing'],
      }),
    );
    expect(
      () => loadPackageGraph(root.path, buildWorkspace: true),
      throwsStateError,
    );
  });

  test('stale workspace graph cannot omit the invoking member', () async {
    await File(
      p.join(root.path, '.dart_tool', 'package_graph.json'),
    ).writeAsString(
      jsonEncode({
        'roots': ['root'],
      }),
    );
    await expectLater(
      generateWorkerCatalog(
        p.join(root.path, 'member'),
        p.join(root.path, 'worker.dart'),
        buildWorkspace: true,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('does not contain the current package'),
        ),
      ),
    );
    expect(File(p.join(root.path, 'worker.dart')).existsSync(), isFalse);
  });

  test('trigger helper loads workspace member dev dependencies', () async {
    await File(p.join(root.path, 'member', 'pubspec.yaml')).writeAsString('''
name: member
resolution: workspace
dev_dependencies:
  missing: any
''');
    final helper = await Isolate.resolvePackageUri(
      Uri.parse(
        'package:build_runner_accelerator/src/manifest/trigger_worker.dart',
      ),
    );
    final packageConfig = File('.dart_tool/package_config.json').absolute.path;
    final result = p.join(root.path, 'triggers.json');
    Future<ProcessResult> run(String workspace) =>
        Process.run(Platform.resolvedExecutable, [
          '--packages=$packageConfig',
          helper!.toFilePath(),
          root.path,
          result,
          'null',
          workspace,
        ]);
    final single = await run('false');
    expect(single.exitCode, 0, reason: '${single.stderr}');
    final workspace = await run('true');
    expect(workspace.exitCode, isNot(0));
    expect(workspace.stderr, contains('Dependency missing of member'));
    await runWorker(
      catalog: {},
      arguments: ['--manifest-triggers', root.path, result, 'null'],
    );
    await expectLater(
      runWorker(
        catalog: {},
        arguments: ['--manifest-triggers', root.path, result, 'null', 'true'],
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Dependency missing of member'),
        ),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
