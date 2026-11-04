import 'dart:io';
import 'package:build_runner_accelerator/src/compiler_package_config.dart';
import 'package:test/test.dart';

void main() {
  test('default and experimental compiler selectors remain independent', () {
    final root = Directory.systemTemp.createTempSync('compiler config ü # ');
    addTearDown(() => root.deleteSync(recursive: true));
    final state = Directory('${root.path}/.dart_tool/build_runner_accelerator')
      ..createSync(recursive: true);
    final original = File('${root.path}/.dart_tool/package_config.json');
    final compatible = File('${state.path}/runner-package_config.json');
    final isolated = File(
      '${state.path}/compile-isolation-package_config.json',
    );
    Uri select(bool enabled) => File(
      compilerPackageConfigPath(root.path, experimentalIsolation: enabled),
    ).absolute.uri;
    expect(select(false), original.absolute.uri);
    expect(select(true), original.absolute.uri);
    expect(hasCompilerPackageConfig(root.path), false);
    isolated.writeAsStringSync('{}');
    expect(select(false), original.absolute.uri);
    expect(select(true), isolated.absolute.uri);
    expect(hasCompilerPackageConfig(root.path), true);
    compatible.writeAsStringSync('{}');
    expect(select(false), compatible.absolute.uri);
    expect(select(true), isolated.absolute.uri);
    isolated.deleteSync();
    expect(select(true), compatible.absolute.uri);
  });
}
