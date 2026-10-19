import 'dart:io';

import 'frontend_binary_resolver.dart';
import 'launcher_options.dart';
import 'manifest/settings.dart';
import 'launcher_process.dart';

export 'frontend_binary_resolver.dart'
    show FrontendBinaryResolver, buildRunnerAcceleratorVersion;
export 'launcher_options.dart' show LauncherOptions;

Future<int> runLauncher(List<String> arguments) async {
  final options = LauncherOptions.parse(arguments);
  if (options.showHelp) {
    stdout.write(launcherHelp);
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

const launcherHelp =
    r'''build_runner_accelerator <build|watch|prewarm|aot-cache-key> [options]

Run supported builders with the native frontend and a Dart worker.
Unsupported requests and unavailable native binaries fail; stock build_runner
is never started. Run dart run build_runner directly when stock is needed.
--mode was removed in 0.14.0; remove it from scripts and CI.

  --root PATH            Workspace directory
  --dart PATH            Dart SDK executable used by the worker
  --jobs N               Worker count (positive integer)
  --interval-ms N        Watch debounce interval (positive integer)
  --force-aot            Force the AOT worker
  --force-jit            Force the non-AOT worker
  --release, --no-release, -r
                         Select builder release settings
  --config NAME, -c NAME Select build.<name>.yaml
  --define BUILDER=OPTION=VALUE
                         Override a builder option
  --build-filter PATTERN Select build/watch outputs; repeat or comma-separate
  --only-check           Build-only verification; report I/M/U, exit 1 on differences
  --keep-modified-outputs Build-only retention until the producer reruns
  --delete-conflicting-outputs, -d
                         Accepted retired stock flags; no effect
  --background           Detach prewarm (prewarm only)
  --help, -h             Show accelerator help
  --version              Show accelerator version

Output policies are mutually exclusive and support the normal-builder demand
subset. Watch after retained output history and retained digest/resolver API use
are unsupported. Filter syntax, builder shapes and state transitions outside the
validated subset fail before publishing outputs. Watch topology changes fail.
Legacy stock output-policy history requires explicit recovery; see
https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/compatibility-cleanup.md#safe-recovery

--output, --workspace, logging options, positional build directories and stock
commands such as clean/serve/run/test/stop are unsupported. Use stock directly.
--worker is an internal test/diagnostic override, not a third-party extension API.
''';
