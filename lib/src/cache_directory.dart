import 'dart:io';

import 'package:path/path.dart' as p;

/// Machine-wide cache root shared by all workspaces.
///
/// `BUILD_RUNNER_ACCELERATOR_CACHE` wins when set; otherwise the platform
/// cache directory is used. A relative override resolves against
/// [workspaceRoot], falling back to the current directory — matching the
/// Rust frontend's `shared_cache_root`, which anchors at the workspace root
/// so the launcher, workers, and release installer agree on one location.
String acceleratorCacheDirectory({
  String? environmentCache,
  String? workspaceRoot,
}) {
  environmentCache ??= Platform.environment['BUILD_RUNNER_ACCELERATOR_CACHE'];
  if (environmentCache != null && environmentCache.isNotEmpty) {
    return p.isAbsolute(environmentCache)
        ? environmentCache
        : p.join(workspaceRoot ?? Directory.current.path, environmentCache);
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
    return p.join(Directory.current.path, '.cache', 'build_runner_accelerator');
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
