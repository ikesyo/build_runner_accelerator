import 'dart:convert';
import 'dart:io';

import 'package:build_runner_accelerator/src/manifest/package_graph.dart';

/// Internal discovery helper for the native frontend. The frontend must
/// recheck the result after acquiring all output-package locks and include
/// the current package and output set in its cached configuration identity.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('usage: resolve_workspace <current-package>');
    exitCode = 64;
    return;
  }
  final current = Directory(arguments.single).absolute.path;
  final paths = manifestBuildPaths(current, buildWorkspace: true);
  final graph = await loadPackageGraph(
    paths.root,
    buildWorkspace: paths.buildWorkspace,
  );
  if (paths.buildWorkspace) {
    validateWorkspaceCurrentPackage(graph, paths.currentPackage, current);
  }
  final outputPackages =
      graph.allPackages.values.where((package) => package.isRoot).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
  stdout.writeln(
    jsonEncode({
      'root': paths.root,
      'current_package': paths.currentPackage,
      'build_workspace': paths.buildWorkspace,
      'output_packages': {
        for (final package in outputPackages) package.name: package.path,
      },
    }),
  );
}
