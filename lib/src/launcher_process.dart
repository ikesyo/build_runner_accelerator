import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

const _releaseDownloaderEntrypoint = 'release_downloader_entrypoint.dart';

abstract interface class FrontendReleaseInstaller {
  Future<String> ensureInstalled({
    required String cacheDirectory,
    required String baseUrl,
    required String version,
    required String target,
    required String binaryName,
    required String? dartBinary,
    required String workingDirectory,
  });
}

/// Runs the release downloader without adding its archive and crypto
/// dependencies to the launcher's normal startup path.
class LauncherReleaseInstaller implements FrontendReleaseInstaller {
  const LauncherReleaseInstaller();

  @override
  Future<String> ensureInstalled({
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
}

class LauncherProcessRunner {
  const LauncherProcessRunner();

  Future<int> run(
    String executable,
    List<String> arguments,
    String workingDirectory, {
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

class _DownloaderSpawnFailure implements Exception {
  _DownloaderSpawnFailure(this.error);

  final Object error;
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
  final response = decodeReleaseDownloaderResponse(output);
  if (response is Map && response['ok'] == true && response['path'] is String) {
    return response['path'] as String;
  }
  final error = response is Map ? response['error'] : response;
  final stack = response is Map ? response['stack'] : null;
  throw StateError(
    'release artifact download failed: $error${stack is String ? '\n$stack' : ''}',
  );
}

Object? decodeReleaseDownloaderResponse(String output) {
  try {
    return jsonDecode(output.split('\n').last);
  } on FormatException catch (error) {
    throw StateError(
      'release downloader process returned invalid JSON: $output\n$error',
    );
  }
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
