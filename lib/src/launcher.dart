import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'release_downloader_api.dart';

const buildRunnerAcceleratorVersion = '0.1.0-dev.1';
const _workerAotEnvironment = 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT';
const _releaseCacheMetadataFilename = 'artifact.json';

/// The small set of launcher options that must be consumed before invoking
/// either the Rust frontend or stock build_runner.
class LauncherOptions {
  LauncherOptions._({
    required this.command,
    required this.mode,
    required this.root,
    required this.dartBinary,
    required this.rustArguments,
    required this.dartArguments,
    required this.forceAot,
    required this.forceJit,
    required this.showHelp,
    required this.showVersion,
  });

  factory LauncherOptions.parse(List<String> arguments) {
    var command = 'build';
    var commandSeen = false;
    var mode = 'auto';
    var root = Directory.current.absolute.path;
    var dartBinary = Platform.resolvedExecutable;
    var forceAot = false;
    var forceJit = false;
    var showHelp = false;
    var showVersion = false;
    final rustArguments = <String>[];
    final dartArguments = <String>[];
    final passthrough = <String>[];

    String takeValue(List<String> values, String option, int index) {
      if (index + 1 >= values.length) {
        throw FormatException('$option requires a value');
      }
      return values[index + 1];
    }

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--help' || argument == '-h') {
        showHelp = true;
        continue;
      }
      if (argument == '--version') {
        showVersion = true;
        continue;
      }
      if (argument == '--mode' || argument.startsWith('--mode=')) {
        final value = argument.startsWith('--mode=')
            ? argument.substring('--mode='.length)
            : takeValue(arguments, '--mode', index);
        if (!argument.startsWith('--mode=')) index++;
        if (!const {'auto', 'rust', 'dart'}.contains(value)) {
          throw FormatException('--mode must be auto, rust, or dart: $value');
        }
        mode = value;
        continue;
      }
      if (argument == '--root' || argument.startsWith('--root=')) {
        final value = argument.startsWith('--root=')
            ? argument.substring('--root='.length)
            : takeValue(arguments, '--root', index);
        if (!argument.startsWith('--root=')) index++;
        root = Directory(value).absolute.path;
        continue;
      }
      if (argument == '--dart' || argument.startsWith('--dart=')) {
        final value = argument.startsWith('--dart=')
            ? argument.substring('--dart='.length)
            : takeValue(arguments, '--dart', index);
        if (!argument.startsWith('--dart=')) index++;
        dartBinary = value;
        continue;
      }
      if (argument == '--force-aot') {
        forceAot = true;
        continue;
      }
      if (argument == '--force-jit') {
        forceJit = true;
        continue;
      }

      if (!commandSeen && !argument.startsWith('-')) {
        command = argument;
        commandSeen = true;
        continue;
      }

      const rustValueOptions = {'--jobs', '--interval-ms', '--worker'};
      if (rustValueOptions.contains(argument)) {
        final value = takeValue(arguments, argument, index);
        index++;
        rustArguments.addAll([argument, value]);
      } else if (argument.startsWith('--jobs=') ||
          argument.startsWith('--interval-ms=') ||
          argument.startsWith('--worker=')) {
        final separator = argument.indexOf('=');
        final option = argument.substring(0, separator);
        final value = argument.substring(separator + 1);
        if (value.isEmpty) throw FormatException('$option requires a value');
        rustArguments.addAll([option, value]);
      } else {
        passthrough.add(argument);
      }
    }

    if (forceAot && forceJit) {
      throw FormatException(
        'Only one compile mode can be used, got --force-aot and --force-jit.',
      );
    }

    rustArguments.insert(0, command);
    rustArguments.addAll([
      '--root',
      root,
      '--dart',
      dartBinary,
      '--mode',
      mode,
    ]);
    dartArguments
      ..addAll(['run', 'build_runner', command])
      ..addAll([if (forceAot) '--force-aot', if (forceJit) '--force-jit'])
      ..addAll(passthrough);
    if (command == 'build' &&
        !passthrough.contains('--delete-conflicting-outputs')) {
      dartArguments.add('--delete-conflicting-outputs');
    }

    return LauncherOptions._(
      command: command,
      mode: mode,
      root: root,
      dartBinary: dartBinary,
      rustArguments: List.unmodifiable(rustArguments),
      dartArguments: List.unmodifiable(dartArguments),
      forceAot: forceAot,
      forceJit: forceJit,
      showHelp: showHelp,
      showVersion: showVersion,
    );
  }

  final String command;
  final String mode;
  final String root;
  final String dartBinary;
  final List<String> rustArguments;
  final List<String> dartArguments;
  final bool forceAot;
  final bool forceJit;
  final bool showHelp;
  final bool showVersion;
}

class FrontendBinaryResolver {
  FrontendBinaryResolver({
    String? environmentCache,
    ReleaseArtifactDownloader? releaseDownloader,
  }) : environmentCache =
           environmentCache ??
           Platform.environment['BUILD_RUNNER_ACCELERATOR_CACHE'],
       releaseDownloader = releaseDownloader;

  final String? environmentCache;
  final ReleaseArtifactDownloader? releaseDownloader;

  Future<String?> resolve(String workspaceRoot, {String? dartBinary}) async {
    final override = Platform.environment['BUILD_RUNNER_ACCELERATOR_BIN'];
    if (override != null && override.isNotEmpty) {
      return _existingFile(_resolvePath(override, Directory.current.path));
    }

    final binaryName = Platform.isWindows
        ? 'build_runner_accelerator.exe'
        : 'build_runner_accelerator';
    final workspaceCandidate = p.join(
      workspaceRoot,
      '.dart_tool',
      'build_runner_accelerator',
      'bin',
      binaryName,
    );
    final workspaceBinary = _existingFile(workspaceCandidate);
    if (workspaceBinary != null) return workspaceBinary;

    final target = await detectTarget();

    final configuredDownloader = releaseDownloader;
    if (configuredDownloader != null) {
      return configuredDownloader.ensureInstalled(
        version: buildRunnerAcceleratorVersion,
        target: target,
        binaryName: binaryName,
      );
    }

    final releaseCacheDirectory = cacheDirectory();
    final cachedRelease = await _validCachedReleaseBinary(
      cacheDirectory: releaseCacheDirectory,
      version: buildRunnerAcceleratorVersion,
      target: target,
      binaryName: binaryName,
    );
    if (cachedRelease != null) return cachedRelease;

    return _ensureInstalled(
      cacheDirectory: releaseCacheDirectory,
      baseUrl:
          Platform.environment['BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL'] ??
          releaseBaseUrl,
      version: buildRunnerAcceleratorVersion,
      target: target,
      binaryName: binaryName,
      dartBinary: dartBinary,
      workingDirectory: workspaceRoot,
    );
  }

  String cacheDirectory() {
    if (environmentCache != null && environmentCache!.isNotEmpty) {
      return _resolvePath(environmentCache!, Directory.current.path);
    }
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return p.join(localAppData, 'build_runner_accelerator');
      }
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        return p.join(
          userProfile,
          'AppData',
          'Local',
          'build_runner_accelerator',
        );
      }
      return p.join(
        Directory.current.path,
        '.cache',
        'build_runner_accelerator',
      );
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      return p.join(
        home ?? Directory.current.path,
        'Library',
        'Caches',
        'build_runner_accelerator',
      );
    }
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return p.join(xdg, 'build_runner_accelerator');
    }
    final home = Platform.environment['HOME'];
    return p.join(
      home ?? Directory.current.path,
      '.cache',
      'build_runner_accelerator',
    );
  }

  static Future<String> detectTarget() async {
    final os = Platform.isMacOS
        ? 'macos'
        : Platform.isWindows
        ? 'windows'
        : Platform.isLinux
        ? 'linux'
        : throw UnsupportedError(
            'Unsupported operating system: ${Platform.operatingSystem}',
          );
    var architecture = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
    if (Platform.isWindows) {
      final emulatedArchitecture =
          Platform.environment['PROCESSOR_ARCHITEW6432'] ?? '';
      if (architecture.isEmpty || architecture.toLowerCase() == 'x86') {
        architecture = emulatedArchitecture;
      }
    }
    if (architecture.isEmpty && !Platform.isWindows) {
      final result = await Process.run('uname', ['-m']);
      if (result.exitCode == 0) architecture = result.stdout.toString().trim();
    }
    architecture = switch (architecture.toLowerCase()) {
      'aarch64' || 'arm64' || 'armv8' => 'arm64',
      'x86_64' || 'amd64' || 'x64' => 'x64',
      _ => throw UnsupportedError(
        'Unsupported CPU architecture: $architecture',
      ),
    };
    if (Platform.isMacOS && architecture == 'x64') {
      throw UnsupportedError(
        'macOS Intel (x86_64) is not supported by released frontend artifacts. '
        'Use --mode dart or set BUILD_RUNNER_ACCELERATOR_BIN.',
      );
    }
    return '$os-$architecture';
  }

  static String? _existingFile(String path) {
    final file = File(path);
    return file.existsSync() ? file.absolute.path : null;
  }

  static String _resolvePath(String path, String base) =>
      p.isAbsolute(path) ? path : p.join(base, path);
}

Future<String?> _validCachedReleaseBinary({
  required String cacheDirectory,
  required String version,
  required String target,
  required String binaryName,
}) async {
  final targetDirectory = Directory(p.join(cacheDirectory, version, target));
  final binary = File(p.join(targetDirectory.path, binaryName));
  final metadataFile = File(
    p.join(targetDirectory.path, _releaseCacheMetadataFilename),
  );
  if (!await binary.exists() || !await metadataFile.exists()) return null;
  if (await FileSystemEntity.type(binary.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return null;
  }

  try {
    final decoded = jsonDecode(await metadataFile.readAsString());
    final archiveFilename = _releaseArchiveFilename(target);
    if (decoded is! Map ||
        decoded['schema_version'] != 1 ||
        decoded['package_version'] != version ||
        decoded['target'] != target ||
        decoded['binary'] != binaryName ||
        decoded['archive'] != archiveFilename ||
        decoded['archive_size'] is! int ||
        decoded['archive_size'] <= 0 ||
        decoded['archive_sha256'] is! String ||
        !_isSha256(decoded['archive_sha256'] as String) ||
        decoded['binary_sha256'] is! String ||
        !_isSha256(decoded['binary_sha256'] as String)) {
      return null;
    }
    final digest = await _sha256File(binary.path);
    if (digest == null || digest != decoded['binary_sha256']) return null;
    return binary.absolute.path;
  } on Object {
    return null;
  }
}

String _releaseArchiveFilename(String target) =>
    'build_runner_accelerator-$target${target.startsWith('windows-') ? '.zip' : '.tar.gz'}';

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Future<String?> _sha256File(String path) async {
  final command = Platform.isWindows
      ? ('certutil', ['-hashfile', path, 'SHA256'])
      : Platform.isMacOS
      ? ('shasum', ['-a', '256', path])
      : ('sha256sum', [path]);
  try {
    final result = await Process.run(command.$1, command.$2);
    if (result.exitCode != 0) return null;
    final match = RegExp(
      r'\b[0-9a-fA-F]{64}\b',
    ).firstMatch(result.stdout.toString());
    return match?.group(0)?.toLowerCase();
  } on Object {
    return null;
  }
}

const _releaseDownloaderEntrypoint = 'release_downloader_entrypoint.dart';

class _DownloaderSpawnFailure implements Exception {
  _DownloaderSpawnFailure(this.error);

  final Object error;
}

Future<String> _ensureInstalled({
  required String cacheDirectory,
  required String baseUrl,
  required String version,
  required String target,
  required String binaryName,
  required String? dartBinary,
  required String workingDirectory,
}) async {
  if (!_launcherRunsFromDartSource()) {
    return _ensureInstalledInProcess(
      cacheDirectory: cacheDirectory,
      baseUrl: baseUrl,
      version: version,
      target: target,
      binaryName: binaryName,
      dartBinary: dartBinary,
      workingDirectory: workingDirectory,
    );
  }
  try {
    return await _ensureInstalledInSpawnedIsolate(
      cacheDirectory: cacheDirectory,
      baseUrl: baseUrl,
      version: version,
      target: target,
      binaryName: binaryName,
    );
  } on _DownloaderSpawnFailure {
    return _ensureInstalledInProcess(
      cacheDirectory: cacheDirectory,
      baseUrl: baseUrl,
      version: version,
      target: target,
      binaryName: binaryName,
      dartBinary: dartBinary,
      workingDirectory: workingDirectory,
    );
  }
}

Future<String> _ensureInstalledInSpawnedIsolate({
  required String cacheDirectory,
  required String baseUrl,
  required String version,
  required String target,
  required String binaryName,
}) async {
  final entrypoint = _findReleaseDownloaderEntrypoint();
  final responsePort = ReceivePort();
  final errorPort = ReceivePort();
  Isolate? downloaderIsolate;
  try {
    try {
      downloaderIsolate = await Isolate.spawnUri(
        entrypoint,
        [cacheDirectory, baseUrl, version, target, binaryName],
        responsePort.sendPort,
        errorsAreFatal: false,
        onError: errorPort.sendPort,
      );
    } on Object catch (error) {
      throw _DownloaderSpawnFailure(error);
    }
    final response =
        await Future.any<Object?>([
          responsePort.first,
          errorPort.first.then(
            (error) => <String, Object>{
              'ok': false,
              'error': 'release downloader isolate failed: $error',
            },
          ),
        ]).timeout(
          const Duration(minutes: 2),
          onTimeout: () => <String, Object>{
            'ok': false,
            'error': 'release downloader isolate timed out',
          },
        );
    if (response is Map &&
        response['ok'] == true &&
        response['path'] is String) {
      return response['path'] as String;
    }
    final error = response is Map ? response['error'] : response;
    final stack = response is Map ? response['stack'] : null;
    throw StateError(
      'release artifact download failed: $error${stack is String ? '\n$stack' : ''}',
    );
  } on TimeoutException {
    throw StateError('release downloader isolate timed out');
  } finally {
    downloaderIsolate?.kill(priority: Isolate.immediate);
    responsePort.close();
    errorPort.close();
  }
}

Future<String> _ensureInstalledInProcess({
  required String cacheDirectory,
  required String baseUrl,
  required String version,
  required String target,
  required String binaryName,
  required String? dartBinary,
  required String workingDirectory,
}) async {
  final entrypoint = _findReleaseDownloaderEntrypoint();
  final packageConfig = Isolate.packageConfigSync;
  final arguments = <String>[
    '--suppress-analytics',
    'run',
    if (packageConfig != null && packageConfig.isScheme('file'))
      '--packages=${packageConfig.toFilePath()}',
    entrypoint.toFilePath(),
    cacheDirectory,
    baseUrl,
    version,
    target,
    binaryName,
  ];
  final result = await Process.run(
    dartBinary ?? 'dart',
    arguments,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    final stderr = result.stderr.toString().trim();
    final stdout = result.stdout.toString().trim();
    throw StateError(
      'release downloader process failed (${result.exitCode}): '
      '${stderr.isNotEmpty ? stderr : stdout}',
    );
  }
  final output = result.stdout.toString().trim();
  if (output.isEmpty) {
    throw StateError('release downloader process returned no result');
  }
  final response = jsonDecode(output.split('\n').last);
  if (response is Map && response['ok'] == true && response['path'] is String) {
    return response['path'] as String;
  }
  final error = response is Map ? response['error'] : response;
  final stack = response is Map ? response['stack'] : null;
  throw StateError(
    'release artifact download failed: $error${stack is String ? '\n$stack' : ''}',
  );
}

bool _launcherRunsFromDartSource() {
  final script = Platform.script;
  return script.isScheme('file') && p.extension(script.toFilePath()) == '.dart';
}

Uri _findReleaseDownloaderEntrypoint() {
  final candidates = <String>[
    p.join(
      File.fromUri(Platform.script).absolute.parent.path,
      '..',
      'lib',
      'src',
      _releaseDownloaderEntrypoint,
    ),
    p.join(Directory.current.path, 'lib', 'src', _releaseDownloaderEntrypoint),
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) return file.absolute.uri;
  }
  try {
    final packageUri = Isolate.resolvePackageUriSync(
      Uri.parse(
        'package:build_runner_accelerator/src/$_releaseDownloaderEntrypoint',
      ),
    );
    if (packageUri != null) {
      final file = File.fromUri(packageUri);
      if (file.existsSync()) return file.absolute.uri;
    }
  } on Object {
    // A compiled or embedded launcher may not expose package resolution.
  }
  throw StateError(
    'release downloader entrypoint is unavailable; reinstall the package',
  );
}

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
  if (options.mode == 'dart') {
    return _runProcess(options.dartBinary, options.dartArguments, options.root);
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
    return _runProcess(options.dartBinary, options.dartArguments, options.root);
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
    return _runProcess(options.dartBinary, options.dartArguments, options.root);
  }
  final environment = Map<String, String>.from(Platform.environment);
  // AOT startup is substantially faster for dirty builds. Keep the setting
  // overridable so users can opt back into the kernel/script worker path when
  // the one-time workspace-local AOT compilation is undesirable.
  if (options.forceAot) {
    environment[_workerAotEnvironment] = 'force';
  } else if (options.forceJit) {
    environment[_workerAotEnvironment] = '0';
  } else {
    environment.putIfAbsent(_workerAotEnvironment, () => '1');
  }
  return _runProcess(
    binary,
    options.rustArguments,
    options.root,
    environment: environment,
  );
}

Future<int> _runProcess(
  String executable,
  List<String> arguments,
  String root, {
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: root,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
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
                               Override worker AOT policy (default: 1)
  BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL  Use a signed HTTPS mirror
  --version              Print the package version
  -h, --help             Show this help
''';
