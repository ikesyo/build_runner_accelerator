import 'dart:io';

import 'frontend_binary_resolver.dart';
import 'launcher_options.dart';
import 'launcher_process.dart';
import 'process_group.dart';

export 'frontend_binary_resolver.dart'
    show FrontendBinaryResolver, buildRunnerAcceleratorVersion;
export 'launcher_options.dart' show LauncherOptions;

const _workerAotEnvironment = 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT';

Future<int> runLauncher(List<String> arguments) async {
  if (arguments.isNotEmpty && arguments.first == processGroupCommand) {
    if (Platform.isWindows || arguments.length < 2) {
      throw FormatException('Invalid internal process-group invocation');
    }
    executeInProcessGroup(arguments[1], arguments.sublist(2));
  }
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
  if (options.mode == 'dart' || options.nativeUnsupported) {
    if (options.command == 'aot-cache-key') {
      throw FormatException('aot-cache-key requires a native frontend');
    }
    if (_isPrewarmCommand(options.command)) {
      // Stock build_runner has no caches to warm; a post-`pub get` hook must
      // not fail when the Rust frontend is deliberately disabled.
      stderr.writeln(
        'build_runner_accelerator: --mode dart leaves nothing to prewarm; '
        'skipping.',
      );
      return 0;
    }
    if (options.nativeUnsupported && options.mode == 'auto') {
      stderr.writeln(
        'build_runner_accelerator: unsupported native CLI; '
        'using Dart build_runner fallback.',
      );
    }
    return processRunner.run(
      options.dartBinary,
      options.dartArguments,
      options.root,
      isolatedProcessGroup: true,
    );
  }

  String? binary;
  try {
    binary = await FrontendBinaryResolver().resolve(
      options.root,
      dartBinary: options.dartBinary,
    );
  } on Object catch (error) {
    if (options.mode == 'rust' || options.command == 'aot-cache-key') {
      throw StateError('Rust frontend is unavailable: $error');
    }
    if (_isPrewarmCommand(options.command)) {
      stderr.writeln(
        'build_runner_accelerator: Rust frontend unavailable ($error); '
        'skipping prewarm.',
      );
      return 0;
    }
    stderr.writeln(
      'build_runner_accelerator: Rust frontend unavailable ($error); '
      'using Dart build_runner fallback.',
    );
    return processRunner.run(
      options.dartBinary,
      options.dartArguments,
      options.root,
      isolatedProcessGroup: true,
    );
  }
  if (binary == null) {
    if (options.mode == 'rust' || options.command == 'aot-cache-key') {
      throw StateError(
        'Rust frontend binary is unavailable for this platform. '
        'Set BUILD_RUNNER_ACCELERATOR_BIN or install a release artifact.',
      );
    }
    if (_isPrewarmCommand(options.command)) {
      stderr.writeln(
        'build_runner_accelerator: Rust frontend unavailable; '
        'skipping prewarm.',
      );
      return 0;
    }
    stderr.writeln(
      'build_runner_accelerator: Rust frontend unavailable; '
      'using Dart build_runner fallback.',
    );
    return processRunner.run(
      options.dartBinary,
      options.dartArguments,
      options.root,
      isolatedProcessGroup: true,
    );
  }
  final environment = Map<String, String>.from(Platform.environment);
  // AOT startup is substantially faster for dirty builds. Long-running
  // commands start the worker immediately and compile it in the background;
  // one-shot commands compile synchronously so the whole build runs on the
  // AOT worker, which is faster end-to-end for large builds. The setting
  // stays overridable for the kernel/script worker path.
  if (options.forceAot) {
    environment[_workerAotEnvironment] = 'force';
  } else if (options.forceJit) {
    environment[_workerAotEnvironment] = '0';
  } else {
    environment.putIfAbsent(
      _workerAotEnvironment,
      () => _defaultWorkerAotPolicy(options.command),
    );
  }
  return processRunner.run(
    binary,
    options.rustArguments,
    options.root,
    environment: environment,
  );
}

/// `prewarm` (and the `aot-prewarm` alias kept for existing CI tooling) only
/// warms frontend caches; when no frontend can run there is nothing to do.
bool _isPrewarmCommand(String command) =>
    command == 'prewarm' || command == 'aot-prewarm';

/// `watch`/`serve` are long-running commands where startup latency matters,
/// so the worker starts on the kernel/script path while the AOT binary is
/// compiled in the background. Every other command is a one-shot where total
/// wall-clock time dominates, so the AOT compile runs before the build.
String _defaultWorkerAotPolicy(String command) =>
    const {'watch', 'serve'}.contains(command) ? 'background' : '1';

const launcherHelp =
    '''Usage: dart run build_runner_accelerator <command> [options]

The launcher uses a cached Rust frontend when available and otherwise falls
back to stock dart build_runner in --mode auto. On a cache miss it downloads
and verifies the matching signed release artifact.

Native commands: build, watch, prewarm (aot-prewarm alias), aot-cache-key.
Other stock commands (clean, serve, run, test, stop) and unsupported options
use stock in auto/dart; rust reports an error before downloading a frontend.
Stock --build-filter, --output, --config, --define, --release, --workspace,
--keep-modified-outputs, --only-check and logging options use fallback.
--delete-conflicting-outputs / -d are accepted by native build/watch as retired
stock compatibility flags: they have no effect. They are never auto-added.
-- ends accelerator option parsing and is retained for stock.
Command --help uses stock help (auto/dart); leading --help is launcher help.

Launcher options:
  --mode auto|rust|dart  Select frontend policy (default: auto)
  --root PATH            Build workspace (default: current directory)
  --dart PATH            Dart executable used by the frontend/fallback
  --jobs N               Rust worker count (default: logical CPUs)
  --interval-ms N        Rust watch debounce interval
  --worker VALUE         Rust worker override
  --background           prewarm only: detach and compile in the background
  --force-aot             Force the AOT worker (stock-compatible)
  --force-jit             Force the non-AOT worker (stock-compatible)
  BUILD_RUNNER_ACCELERATOR_BIN   Use a preinstalled frontend binary
  BUILD_RUNNER_ACCELERATOR_CACHE Override the frontend cache directory
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT
                               Override worker AOT policy (default:
                               synchronous for build, background for
                               watch/serve)
  BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL  Use a signed HTTPS mirror
  --version              Print the package version
  -h, --help             Show this help
''';
