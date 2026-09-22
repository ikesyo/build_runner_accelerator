import 'dart:io';

import 'package:path/path.dart' as p;

import 'launcher_process.dart';
import 'release_cache_metadata.dart';
import 'release_downloader_api.dart';

const buildRunnerAcceleratorVersion = '0.4.1';

/// Resolves the native frontend in the same order as the launcher contract:
/// explicit override, workspace output, user cache, then release download.
class FrontendBinaryResolver {
  FrontendBinaryResolver({
    String? environmentCache,
    ReleaseArtifactDownloader? releaseDownloader,
    FrontendReleaseInstaller? releaseInstaller,
  }) : environmentCache =
           environmentCache ??
           Platform.environment['BUILD_RUNNER_ACCELERATOR_CACHE'],
       releaseDownloader = releaseDownloader,
       releaseInstaller = releaseInstaller ?? const LauncherReleaseInstaller();

  final String? environmentCache;
  final ReleaseArtifactDownloader? releaseDownloader;
  final FrontendReleaseInstaller releaseInstaller;

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
    final cachedRelease = await ReleaseCacheMetadata.validBinary(
      cacheDirectory: releaseCacheDirectory,
      version: buildRunnerAcceleratorVersion,
      target: target,
      binaryName: binaryName,
    );
    if (cachedRelease != null) return cachedRelease;

    return releaseInstaller.ensureInstalled(
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
