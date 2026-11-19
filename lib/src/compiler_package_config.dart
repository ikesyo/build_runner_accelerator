import 'dart:io';

import 'package:build_runner/src/build_plan/build_paths.dart';

const experimentalCompileIsolationEnvironment =
    'BUILD_RUNNER_ACCELERATOR_EXPERIMENTAL_COMPILE_ISOLATION';

File _config(String root, String name) => File.fromUri(
  Directory(
    root,
  ).absolute.uri.resolve('.dart_tool/build_runner_accelerator/$name'),
);

/// Read the original resolution from the same directory as stock Build Runner.
File pubPackageConfigFile(String root) {
  final packagePath = Directory(root).absolute.path;
  final paths = BuildPaths.load(packagePath, buildWorkspace: false);
  return File.fromUri(
    Directory(
      paths.workspacePath ?? packagePath,
    ).uri.resolve('.dart_tool/package_config.json'),
  );
}

/// Compiler copies must never become the builder's asset/package namespace.
/// An old experimental selector may remain after opting out; restoring the
/// current original config is still correct in that case.
bool hasCompilerPackageConfig(String root) =>
    _config(root, 'runner-package_config.json').existsSync() ||
    _config(root, 'compile-isolation-package_config.json').existsSync();

/// Keep default and experimental compiler selection independent.
String compilerPackageConfigPath(String root, {bool? experimentalIsolation}) {
  final isolated = _config(root, 'compile-isolation-package_config.json');
  final enabled =
      experimentalIsolation ??
      Platform.environment[experimentalCompileIsolationEnvironment] == '1';
  if (enabled && isolated.existsSync()) return isolated.path;
  final compatible = _config(root, 'runner-package_config.json');
  if (compatible.existsSync()) return compatible.path;
  return pubPackageConfigFile(root).path;
}
