import 'dart:convert';
import 'dart:io';

import 'package:build_runner_accelerator/src/launcher_options.dart';
import 'package:build_runner_accelerator/src/manifest/settings.dart';
import 'package:test/test.dart';

void main() {
  final cases =
      jsonDecode(File('test/data/cli_contract.json').readAsStringSync())
          as List;
  for (final raw in cases) {
    final c = raw as Map;
    test('shared CLI contract: ${c['name']}', () {
      final args = (c['args'] as List).cast<String>();
      if (c['accepted'] == false) {
        expect(() => LauncherOptions.parse(args), throwsFormatException);
        return;
      }
      final options = LauncherOptions.parse(args);
      expect(options.showHelp, c['help']);
      expect(options.showVersion, c['version']);
      if (options.showHelp || options.showVersion) return;
      final arguments = (c['build_arguments'] as List).cast<String>();
      // The launcher must preserve the original settings and their boundaries.
      expect(
        options.rustArguments.skip(
          options.rustArguments.length - arguments.length,
        ),
        arguments,
      );
      final settings = BuildSettings.parse(arguments);
      final expected = c['settings'] as Map;
      expect(options.config, expected['config']);
      expect(
        options.config == null
            ? null
            : BuildSettings.configPath(options.config!),
        expected['config_path'],
      );
      expect(settings.release, expected['release']);
      expect(settings.defines, expected['defines']);
      expect(settings.experiments, expected['experiments']);
      expect(settings.buildFilters.length, expected['filters']);
      expect(settings.onlyCheck, expected['only_check']);
      expect(settings.keepModifiedOutputs, expected['keep_modified_outputs']);
      expect(settings.deletionFlag, expected['deletion']);
      if (c['name'] == 'build --workspace') expect(settings.workspace, isTrue);
    });
  }
}
