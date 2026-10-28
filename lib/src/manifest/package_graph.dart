import 'dart:convert';
import 'dart:io';

import 'package:build_config/build_config.dart';
import 'package:build_runner/src/build_plan/build_paths.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'model.dart';
import 'settings.dart';

/// Resolves stock's current package and output root before loading a manifest.
/// A workspace request outside a pub workspace falls back to a package build.
({String root, String currentPackage, bool buildWorkspace}) manifestBuildPaths(
  String packagePath, {
  required bool buildWorkspace,
}) {
  final packageRoot = p.canonicalize(packagePath);
  final name = _pubspecForPath(packageRoot)['name'];
  if (name is! String || name.isEmpty) {
    throw StateError('The current package has no name in pubspec.yaml.');
  }
  final paths = BuildPaths.load(packageRoot, buildWorkspace: buildWorkspace);
  return (
    root: p.canonicalize(paths.outputRootPath),
    currentPackage: name,
    buildWorkspace: paths.buildWorkspace,
  );
}

/// Refuse a stale pub graph that no longer lists the invoking workspace member.
void validateWorkspaceCurrentPackage(
  PackageGraph graph,
  String currentPackage,
  String packagePath,
) {
  final package = graph.allPackages[currentPackage];
  if (package == null ||
      !package.isRoot ||
      !p.equals(
        Directory(package.path).resolveSymbolicLinksSync(),
        Directory(packagePath).resolveSymbolicLinksSync(),
      )) {
    throw StateError(
      'Workspace package graph does not contain the current package '
      '$currentPackage at $packagePath; run `dart pub get` first.',
    );
  }
}

/// Loads the package graph data needed by manifest generation.
///
/// Keep this adapter local to the worker package. The manifest generator only
/// needs package names, paths, root markers, and direct dependencies; it does
/// not need to depend on build_runner_core's retired graph implementation.
/// For [buildWorkspace], [packagePath] must be the workspace output root.
Future<PackageGraph> loadPackageGraph(
  String packagePath, {
  bool buildWorkspace = false,
}) async {
  final root = p.canonicalize(packagePath);
  final rootPubspec = _pubspecForPath(root);
  final rootName = rootPubspec['name'];
  if (rootName is! String || rootName.isEmpty) {
    throw StateError('The current package has no name in pubspec.yaml.');
  }

  var packageConfigRoot = root;
  PackageConfig? packageConfig;
  while (true) {
    packageConfig = await findPackageConfig(
      Directory(packageConfigRoot),
      recurse: false,
    );
    if (packageConfig != null) break;
    final parent = p.dirname(packageConfigRoot);
    if (parent == packageConfigRoot) break;
    packageConfigRoot = parent;
  }
  if (packageConfig == null) {
    throw StateError('Unable to find package_config.json for $root.');
  }

  // Pub's package graph provides the flattened list of workspace roots,
  // including nested members. Reject missing roots and unknown packages.
  final outputPackages = <String>{rootName};
  if (buildWorkspace) {
    final graphFile = File(p.join(root, '.dart_tool', 'package_graph.json'));
    final graph = jsonDecode(await graphFile.readAsString());
    if (graph is! Map ||
        graph['roots'] is! List ||
        (graph['roots'] as List).any((name) => name is! String)) {
      throw StateError('Invalid workspace package graph: ${graphFile.path}');
    }
    final roots = (graph['roots'] as List).cast<String>();
    if (!roots.contains(rootName)) {
      throw StateError('Workspace package graph does not contain $rootName.');
    }
    outputPackages.addAll(roots);
  }

  final packages = <String, PackageInfo>{};
  final orderedPackages = packageConfig.packages.toList()
    ..sort((left, right) => left.name.compareTo(right.name));
  for (final package in orderedPackages) {
    packages[package.name] = PackageInfo(
      name: package.name,
      path: package.root.toFilePath(),
      isRoot: outputPackages.contains(package.name),
    );
  }

  PackageInfo packageNode(String name, {String? parent}) {
    final node = packages[name];
    if (node == null) {
      throw StateError(
        'Dependency $name ${parent == null ? '' : 'of $parent '}not '
        'present; run `dart pub get` first.',
      );
    }
    return node;
  }

  final rootNode = packageNode(rootName);
  for (final output in outputPackages) {
    packageNode(output);
  }
  for (final package in orderedPackages) {
    final pubspec = package.name == rootName
        ? rootPubspec
        : _pubspecForPath(package.root.toFilePath());
    packages[package.name]!.dependencies.addAll(
      _depsFromYaml(
        pubspec,
        includeDevDependencies: outputPackages.contains(package.name),
      ).map((name) => packageNode(name, parent: package.name)),
    );
  }

  return PackageGraph(root: rootNode, allPackages: packages);
}

/// Loads build configuration after the package graph has been resolved.
Future<Map<String, BuildConfig>> loadBuildConfigs(
  PackageGraph packageGraph, {
  String? configKey,
}) async {
  final configs = <String, BuildConfig>{};
  for (final package in packageGraph.allPackages.values) {
    if (package.name == r'$sdk') continue;
    configs[package.name] = await BuildConfig.fromBuildConfigDir(
      package.name,
      package.dependencies.map((dependency) => dependency.name),
      package.path,
    );
  }
  // Stock loads root-level <package>.build.yaml overrides before the
  // selected root build.<config>.yaml. These replace whole BuildConfigs.
  final overrides =
      Directory(packageGraph.root.path)
          .listSync()
          .whereType<File>()
          .where((file) => p.basename(file.path).endsWith('.build.yaml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final seen = <String>{};
  for (final file in overrides) {
    final name = p.basename(file.path).split('.').first;
    final package = packageGraph.allPackages[name];
    if (package == null) {
      stderr.writeln(
        'Ignoring build config override for unknown package: $name',
      );
      continue;
    }
    if (!seen.add(name)) {
      throw StateError('Ambiguous build config overrides for $name');
    }
    configs[name] = BuildConfig.parse(
      name,
      package.dependencies.map((dependency) => dependency.name),
      file.readAsStringSync(),
      configYamlPath: file.path,
    );
  }
  if (configKey != null) {
    final package = packageGraph.root;
    final file = File(
      p.join(package.path, BuildSettings.configPath(configKey)),
    );
    if (!file.existsSync())
      throw StateError(
        'Cannot find build.$configKey.yaml for specified config.',
      );
    configs[package.name] = BuildConfig.parse(
      package.name,
      package.dependencies.map((dependency) => dependency.name),
      file.readAsStringSync(),
      configYamlPath: file.path,
    );
  }
  return configs;
}

YamlMap _pubspecForPath(String packagePath) {
  final path = p.join(packagePath, 'pubspec.yaml');
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('Unable to find $path.');
  }
  final value = loadYaml(file.readAsStringSync());
  if (value is! YamlMap) {
    throw StateError('$path does not contain a YAML map.');
  }
  return value;
}

List<String> _depsFromYaml(
  YamlMap pubspec, {
  bool includeDevDependencies = false,
}) {
  final dependencies = <String>{
    ..._yamlStringKeys(pubspec['dependencies'] as Map?),
    if (includeDevDependencies)
      ..._yamlStringKeys(pubspec['dev_dependencies'] as Map?),
  };
  return dependencies.toList()..sort();
}

Iterable<String> _yamlStringKeys(Map? values) =>
    values == null ? const <String>[] : values.keys.cast<String>();
