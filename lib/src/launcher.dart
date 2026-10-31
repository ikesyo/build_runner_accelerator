import 'dart:io';

import 'frontend_binary_resolver.dart';
import 'launcher_options.dart';
import 'launcher_help.dart';
import 'manifest/settings.dart';
import 'launcher_process.dart';

export 'frontend_binary_resolver.dart'
    show FrontendBinaryResolver, buildRunnerAcceleratorVersion;
export 'launcher_options.dart' show LauncherOptions;

Future<int> runLauncher(List<String> arguments) async {
  final options = LauncherOptions.parse(arguments);
  if (options.showHelp) {
    stdout.write(launcherHelpFor(options.helpCommand));
    return 0;
  }
  if (options.showVersion) {
    stdout.writeln(buildRunnerAcceleratorVersion);
    return 0;
  }
  if (const {'build', 'watch'}.contains(options.command) &&
      File(
        '${options.root}/.dart_tool/build_runner_accelerator/stock-output-policy-state',
      ).existsSync()) {
    throw StateError(
      'Legacy stock output-policy history cannot be reused; stop all builders '
      'and reset both build states as described in docs/compatibility-cleanup.md#safe-recovery.',
    );
  }
  final config = options.config;
  if (config != null &&
      !File(
        '${options.root}/${BuildSettings.configPath(config)}',
      ).existsSync()) {
    throw StateError('configuration file not found: build.$config.yaml');
  }
  final binary = await FrontendBinaryResolver().resolve(
    options.root,
    dartBinary: options.dartBinary,
  );
  if (binary == null) {
    throw StateError(
      'Native frontend binary is unavailable for this platform. '
      'Set BUILD_RUNNER_ACCELERATOR_BIN or install a release artifact. '
      'Run dart run build_runner directly if needed.',
    );
  }
  return const LauncherProcessRunner().run(
    binary,
    options.rustArguments,
    options.root,
  );
}
