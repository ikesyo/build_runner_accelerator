import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('workspace member produces a manifest for every output package', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'manifest-workspace-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final manifestLibrary = await Isolate.resolvePackageUri(
      Uri.parse('package:build_runner_accelerator/src/builder_manifest.dart'),
    );
    final accelerator = p.dirname(
      p.dirname(p.dirname(manifestLibrary!.toFilePath())),
    );
    final member = Directory(p.join(workspace.path, 'member'));
    final generator = Directory(p.join(workspace.path, 'generator'));
    await member.create();
    await Directory(p.join(generator.path, 'lib')).create(recursive: true);
    await File(p.join(workspace.path, 'pubspec.yaml')).writeAsString('''
name: workspace_root
publish_to: none
environment:
  sdk: ">=3.11.0 <4.0.0"
workspace: [member, generator]
dev_dependencies:
  build_runner_accelerator:
    path: ${jsonEncode(accelerator)}
''');
    await File(p.join(member.path, 'pubspec.yaml')).writeAsString('''
name: workspace_member
publish_to: none
resolution: workspace
environment:
  sdk: ">=3.11.0 <4.0.0"
dev_dependencies:
  workspace_generator:
    path: ../generator
''');
    await File(p.join(generator.path, 'pubspec.yaml')).writeAsString('''
name: workspace_generator
publish_to: none
resolution: workspace
environment:
  sdk: ">=3.11.0 <4.0.0"
dependencies:
  build: any
''');
    await File(p.join(generator.path, 'build.yaml')).writeAsString('''
builders:
  copy:
    import: "package:workspace_generator/builder.dart"
    builder_factories: ["copyBuilder"]
    build_extensions: {".txt": [".out"]}
    auto_apply: root_package
    build_to: source
''');
    await File(p.join(generator.path, 'lib', 'builder.dart')).writeAsString('''
import 'package:build/build.dart';
Builder copyBuilder(BuilderOptions options) => CopyBuilder();
class CopyBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {'.txt': ['.out']};
  @override
  Future<void> build(BuildStep step) async {}
}
''');
    final pub = await Process.run(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'pub',
      'get',
      '--offline',
    ], workingDirectory: workspace.path);
    expect(pub.exitCode, 0, reason: '${pub.stdout}\n${pub.stderr}');
    final discovery = await Process.run(Platform.resolvedExecutable, [
      '--packages=${p.join(workspace.path, '.dart_tool', 'package_config.json')}',
      p.join(accelerator, 'tool', 'resolve_workspace.dart'),
      member.path,
    ], workingDirectory: member.path);
    expect(discovery.exitCode, 0, reason: '${discovery.stderr}');
    final discovered = jsonDecode(discovery.stdout as String) as Map;
    expect(discovered['root'], workspace.path);
    expect(discovered['current_package'], 'workspace_member');
    expect(discovered['build_workspace'], isTrue);
    expect(
      (discovered['output_packages'] as Map).keys,
      unorderedEquals([
        'workspace_root',
        'workspace_member',
        'workspace_generator',
      ]),
    );
    final manifest = File(p.join(workspace.path, 'manifest.json'));
    final generation = await Process.run(Platform.resolvedExecutable, [
      '--packages=${p.join(workspace.path, '.dart_tool', 'package_config.json')}',
      p.join(accelerator, 'tool', 'generate_builder_manifest.dart'),
      '--root',
      member.path,
      '--manifest',
      manifest.path,
      '--worker-entrypoint',
      p.join(workspace.path, 'worker.dart'),
      '--fingerprint',
      'workspace-test',
      '--workspace-json',
      'true',
    ], workingDirectory: member.path);
    expect(
      generation.exitCode,
      0,
      reason: '${generation.stdout}\n${generation.stderr}',
    );
    final earlyWorker = p.join(workspace.path, 'early_worker.dart');
    final early = await Process.run(Platform.resolvedExecutable, [
      '--packages=${p.join(workspace.path, '.dart_tool', 'package_config.json')}',
      p.join(accelerator, 'tool', 'generate_worker_catalog.dart'),
      member.path,
      earlyWorker,
      '[]',
      'true',
    ], workingDirectory: member.path);
    expect(early.exitCode, 0, reason: '${early.stdout}\n${early.stderr}');
    expect(
      await File(earlyWorker).readAsBytes(),
      await File(p.join(workspace.path, 'worker.dart')).readAsBytes(),
    );
    final data =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final builders = (data['builders'] as List).cast<Map<String, dynamic>>();
    final memberBuilder = builders.singleWhere(
      (builder) =>
          builder['package'] == 'workspace_member' &&
          builder['id'] == 'workspace_generator:copy',
    );
    expect(memberBuilder['is_root'], isTrue);
    expect(
      memberBuilder['package_dependencies'],
      contains('workspace_generator'),
    );
    expect(
      memberBuilder['target_dependencies'],
      contains('workspace_generator:workspace_generator'),
    );
    expect(memberBuilder['build_to'], 'source');
    expect(
      builders.where((builder) => builder['package'] == 'workspace_root'),
      isEmpty,
    );
    final sources = data['asset_sources'] as Map<String, dynamic>;
    expect((sources['workspace_member'] as Map)['public_assets'], isNull);
    final graphFile = File(
      p.join(workspace.path, '.dart_tool', 'package_graph.json'),
    );
    final graph =
        jsonDecode(await graphFile.readAsString()) as Map<String, dynamic>;
    (graph['roots'] as List).remove('workspace_member');
    await graphFile.writeAsString(jsonEncode(graph));
    final stale = await Process.run(Platform.resolvedExecutable, [
      '--packages=${p.join(workspace.path, '.dart_tool', 'package_config.json')}',
      p.join(accelerator, 'tool', 'resolve_workspace.dart'),
      member.path,
    ], workingDirectory: member.path);
    expect(stale.exitCode, isNot(0));
    expect(stale.stdout, isEmpty);
    expect(stale.stderr, contains('does not contain the current package'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
