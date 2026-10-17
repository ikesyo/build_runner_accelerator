import 'dart:io';

import 'frontend_binary_resolver.dart';
import 'launcher_options.dart';
import 'manifest/settings.dart';
import 'native_graph.dart';
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
  var unsupportedReason = options.nativeUnsupported
      ? 'unsupported native CLI'
      : null;
  if (unsupportedReason == null &&
      options.mode != 'dart' &&
      const {'build', 'watch'}.contains(options.command) &&
      File(
        '${options.root}/.dart_tool/build_runner_accelerator/stock-output-policy-state',
      ).existsSync()) {
    unsupportedReason =
        'stock output-policy state requires stock until both build states are reset';
    if (options.mode == 'rust') throw StateError(unsupportedReason);
  }
  bool? retainedNativeOutputState;
  if (unsupportedReason == null &&
      options.mode != 'dart' &&
      options.command == 'watch' &&
      (retainedNativeOutputState = hasRetainedNativeOutputState(
        options.root,
      ))) {
    unsupportedReason = 'watch after retained output state requires stock';
    if (options.mode == 'rust') throw StateError(unsupportedReason);
  }
  if (unsupportedReason == null && options.mode != 'dart') {
    final config = BuildSettings.parse(
      options.dartArguments.skip(3).toList(),
    ).config;
    if (config != null &&
        !File(
          '${options.root}/${BuildSettings.configPath(config)}',
        ).existsSync()) {
      unsupportedReason = 'configuration file not found: build.$config.yaml';
      if (options.mode == 'rust' || options.command == 'aot-cache-key') {
        throw StateError(unsupportedReason);
      }
    }
  }
  if (options.mode == 'dart' || unsupportedReason != null) {
    if (options.command == 'aot-cache-key') {
      throw FormatException('aot-cache-key requires a native frontend');
    }
    if (_isPrewarmCommand(options.command)) {
      // Stock build_runner has no caches to warm; a post-`pub get` hook must
      // not fail when the Rust frontend is deliberately disabled.
      stderr.writeln(
        'build_runner_accelerator: ${unsupportedReason ?? '--mode dart'} leaves nothing to prewarm; '
        'skipping.',
      );
      return 0;
    }
    if (unsupportedReason != null && options.mode == 'auto') {
      stderr.writeln(
        'build_runner_accelerator: $unsupportedReason; '
        'using Dart build_runner fallback.',
      );
    }
    return _runStock(
      options,
      processRunner,
      retainedNativeOutputState: retainedNativeOutputState,
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
    return _runStock(options, processRunner);
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
    return _runStock(options, processRunner);
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

// Stock keep can publish logical digests that the native graph cannot import.
// Claim ownership before starting it, including when the process is interrupted.
// Claims remain until explicit recovery: another invocation may have adopted one.
Future<int> _runStock(
  LauncherOptions options,
  LauncherProcessRunner runner, {
  bool? retainedNativeOutputState,
}) async {
  final marker = File(
    '${options.root}/.dart_tool/build_runner_accelerator/stock-output-policy-state',
  );
  var claimOwnership = options.stockKeepRequested;
  if (!marker.existsSync() &&
      options.stockMayPublishOutputs &&
      !claimOwnership &&
      const {'build', 'watch'}.contains(options.command)) {
    try {
      claimOwnership =
          retainedNativeOutputState ??
          hasRetainedNativeOutputState(options.root);
    } on FileSystemException {
      // Stock was already selected. Unreadable native history must not block
      // it or let a subsequent native build reuse history stock may replace.
      claimOwnership = true;
    }
  }
  if (!marker.existsSync() &&
      options.stockMayPublishOutputs &&
      claimOwnership) {
    try {
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('Stock owns output-policy history.\n');
    } on FileSystemException catch (error) {
      if (options.mode != 'dart') rethrow;
      stderr.writeln(
        'build_runner_accelerator: cannot record stock output-policy history '
        '($error); reset both build states before native reuse.',
      );
    }
  }
  return runner.run(
    options.dartBinary,
    options.dartArguments,
    options.root,
    isolatedProcessGroup: true,
  );
}

/// `prewarm` only
/// warms frontend caches; when no frontend can run there is nothing to do.
bool _isPrewarmCommand(String command) => command == 'prewarm';

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

Native commands: build, watch, prewarm, aot-cache-key.
Other stock commands (clean, serve, run, test, stop) and unsupported options
use stock in auto/dart; rust reports an error before downloading a frontend.
Stock --output, --workspace and logging options use fallback.
Build --only-check verifies package outputs without writes/deletes or graph saves;
I/M/U differences fail with status 1. --keep-modified-outputs retains edits until
producer rerun; missing outputs regenerate. Mutually exclusive, non-negatable;
watch uses stock and prewarm rejects both. Normal-builder demand subset only.
Keep with modified outputs and digest/resolver API use requires stock (rust errors).
After stock keep/history fallback, build/watch stay on stock until both states reset.
--delete-conflicting-outputs / -d are accepted by native build/watch as retired
stock compatibility flags: they have no effect. They are never auto-added.
Build/watch filters support repeated/comma-separated relative, package: and
asset: paths, package * and path */whole ** globs. Required producer builders
run on demand; all sibling outputs remain allowed. No match succeeds.
Optional/post-process/zero-output/trigger-only builders and complex URI/glob syntax use stock
(or error in rust). Removed prior output applications or legacy state without
ordered stock inputs/glob evidence also use fallback. Incremental cyclic resolver reuse uses stock. Other filtered
configuration changes without stock plan-compatibility evidence use stock.
Prewarm rejects filters. Unselected outputs may be deleted
on later builds or watch restarts depending on previous incremental state.
Config/define/release apply to native build/watch/prewarm for supported manifests.
Define duplicates are errors. -cNAME and grouped -rd/-dr follow stock parsing.
Config resolves build.<name>.yaml using stock AssetId path normalization.
Watch application/output topology changes use stock (auto) or error (rust).
-- ends accelerator option parsing and is retained for stock.
Command --help uses stock help (auto/dart); leading --help is launcher help.

Launcher options:
  --mode auto|rust|dart  Select frontend policy (default: auto)
  --root PATH            Build workspace (default: current directory)
  --dart PATH            Dart executable used by the frontend/fallback
  --jobs N               Rust worker count (unfiltered default: machine CPU count,
                         memory-capped where supported;
                         filtered default: 1)
  --interval-ms N        Rust watch debounce interval
  --worker VALUE         Internal worker artifact override (tests/diagnostics)
  --background           prewarm only: detach and compile in the background
  --define BUILDER=OPTION=VALUE  Override builder options (JSON or exact string)
  --release, -r          Use release options (default: development)
  --no-release           Use development options; last release flag wins
  --config NAME, -c NAME Use build.NAME.yaml; last config wins
  --only-check           Verify outputs without publishing outputs or graph
  --keep-modified-outputs Keep edits until input changes rerun their producer
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
