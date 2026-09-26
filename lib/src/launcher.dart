import 'dart:io';

import 'frontend_binary_resolver.dart';
import 'launcher_options.dart';
import 'launcher_process.dart';

export 'frontend_binary_resolver.dart'
    show FrontendBinaryResolver, buildRunnerAcceleratorVersion;
export 'launcher_options.dart' show LauncherOptions;

const _workerAotEnvironment = 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT';

Future<int> runLauncher(List<String> arguments) async {
  final options = LauncherOptions.parse(arguments);
  final processRunner = const LauncherProcessRunner();
  if (options.showHelp) {
    stdout.write(launcherHelp);
    return 0;
  }
  if (options.showVersion) {
    stdout.writeln(buildRunnerAcceleratorVersion);
    return 0;
  }
  if (options.mode == 'dart') {
    return processRunner.run(
      options.dartBinary,
      options.dartArguments,
      options.root,
    );
  }

  String? binary;
  try {
    binary = await FrontendBinaryResolver().resolve(
      options.root,
      dartBinary: options.dartBinary,
    );
  } on Object catch (error) {
    if (options.mode == 'rust') {
      throw StateError('Rust frontend is unavailable: $error');
    }
    stderr.writeln(
      'build_runner_accelerator: Rust frontend unavailable ($error); '
      'using Dart build_runner fallback.',
    );
    return processRunner.run(
      options.dartBinary,
      options.dartArguments,
      options.root,
    );
  }
  if (binary == null) {
    if (options.mode == 'rust') {
      throw StateError(
        'Rust frontend binary is unavailable for this platform. '
        'Set BUILD_RUNNER_ACCELERATOR_BIN or install a release artifact.',
      );
    }
    stderr.writeln(
      'build_runner_accelerator: Rust frontend unavailable; '
      'using Dart build_runner fallback.',
    );
    return processRunner.run(
      options.dartBinary,
      options.dartArguments,
      options.root,
    );
  }
  final environment = Map<String, String>.from(Platform.environment);
  // AOT startup is substantially faster for dirty builds. Compile it in the
  // background so the first build does not wait on the one-time
  // workspace-local compilation; keep the setting overridable so users can
  // opt back into the synchronous or kernel/script worker path.
  if (options.forceAot) {
    environment[_workerAotEnvironment] = 'force';
  } else if (options.forceJit) {
    environment[_workerAotEnvironment] = '0';
  } else {
    environment.putIfAbsent(_workerAotEnvironment, () => 'background');
  }
  return processRunner.run(
    binary,
    options.rustArguments,
    options.root,
    environment: environment,
  );
}

const launcherHelp =
    '''Usage: dart run build_runner_accelerator <build|watch> [options]

The launcher uses a cached Rust frontend when available and otherwise falls
back to stock dart build_runner in --mode auto. On a cache miss it downloads
and verifies the matching signed release artifact.

Launcher options:
  --mode auto|rust|dart  Select frontend policy (default: auto)
  --root PATH            Build workspace (default: current directory)
  --dart PATH            Dart executable used by the frontend/fallback
  --jobs N               Rust worker count
  --interval-ms N        Rust watch debounce interval
  --worker VALUE         Rust worker override
  --force-aot             Force the AOT worker (stock-compatible)
  --force-jit             Force the non-AOT worker (stock-compatible)
  BUILD_RUNNER_ACCELERATOR_BIN   Use a preinstalled frontend binary
  BUILD_RUNNER_ACCELERATOR_CACHE Override the frontend cache directory
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT
                               Override worker AOT policy (default: background)
  BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL  Use a signed HTTPS mirror
  --version              Print the package version
  -h, --help             Show this help
''';
