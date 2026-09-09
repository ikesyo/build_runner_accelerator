/// Lightweight contract used by the launcher for release artifact downloads.
///
/// Keep this file free of archive, crypto, and HTTP implementation imports so
/// the normal launcher startup path stays small.
const releaseBaseUrl =
    'https://github.com/ikesyo/build_runner_accelerator/releases/download';

abstract interface class ReleaseArtifactDownloader {
  Future<String> ensureInstalled({
    required String version,
    required String target,
    required String binaryName,
  });
}
