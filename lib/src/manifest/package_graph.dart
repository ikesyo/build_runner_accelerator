import 'dart:io';

import 'package:build_config/build_config.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'model.dart';

/// Loads the package graph data needed by manifest generation.
///
/// Keep this adapter local to the worker package. The manifest generator only
/// needs package names, paths, root markers, and direct dependencies; it does
/// not need to depend on build_runner_core's retired graph implementation.
Future<PackageGraph> loadPackageGraph(String packagePath) async {
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

  final packages = <String, PackageInfo>{};
  final orderedPackages = packageConfig.packages.toList()
    ..sort((left, right) => left.name.compareTo(right.name));
  for (final package in orderedPackages) {
    packages[package.name] = PackageInfo(
      name: package.name,
      path: package.root.toFilePath(),
      isRoot: package.name == rootName,
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
  rootNode.dependencies.addAll(
    _depsFromYaml(
      rootPubspec,
      includeDevDependencies: true,
    ).map((name) => packageNode(name, parent: rootName)),
  );
  for (final package in orderedPackages.where((p) => p.name != rootName)) {
    final pubspec = _pubspecForPath(package.root.toFilePath());
    packages[package.name]!.dependencies.addAll(
      _depsFromYaml(
        pubspec,
      ).map((name) => packageNode(name, parent: package.name)),
    );
  }

  return PackageGraph(root: rootNode, allPackages: packages);
}

/// Loads build configuration after the package graph has been resolved.
Future<Map<String, BuildConfig>> loadBuildConfigs(
  PackageGraph packageGraph,
) async {
  final configs = <String, BuildConfig>{};
  for (final package in packageGraph.allPackages.values) {
    if (package.name == r'$sdk') continue;
    configs[package.name] = await BuildConfig.fromBuildConfigDir(
      package.name,
      package.dependencies.map((dependency) => dependency.name),
      package.path,
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
