import 'dart:io';

/// Per-action resolver diagnostics, enabled by
/// `BUILD_RUNNER_ACCELERATOR_METRICS=1`.
///
/// Workers process one action at a time, so a process-wide sink is enough:
/// the worker resets it when an action starts and reads it when the action
/// finishes. Nothing here prints; the build profile serializes it to stderr.
final class ResolverActionMetrics {
  ResolverActionMetrics()
    : enabled = Platform.environment['BUILD_RUNNER_ACCELERATOR_METRICS'] == '1';

  final bool enabled;

  /// `LibraryCycleGraphLoader.libraryCycleGraphOf` inside `updateDriver`.
  int cycleGraphWalkUs = 0;

  /// Asset-dep loads performed while walking the cycle graph.
  int cycleGraphFileLoads = 0;

  /// Content-keyed directive-deps cache ([AssetDepsCache]) traffic.
  int depParseCacheHits = 0;
  int depParseCacheMisses = 0;
  int depParseCacheUs = 0;

  /// `BuilderFilesystem.readPhased` inside dep loads.
  int depReadPhasedUs = 0;

  /// `parseString` for dep files that miss the cache.
  int depParseUs = 0;

  /// `AnalysisDriverForPackageBuild.applyPendingFileChanges`.
  int applyPendingChangesUs = 0;

  /// `AnalysisDriverFilesystem.phase` setter inside `updateDriver`.
  int filesystemPhaseSyncUs = 0;

  /// Asset `read` RPCs issued by [RemoteAssetReaderWriter].
  int ipcReadCalls = 0;
  int ipcReadUs = 0;
  int ipcReadBytes = 0;
  int ipcReadCacheHits = 0;

  /// Asset `can_read` RPCs.
  int ipcCanReadCalls = 0;
  int ipcCanReadUs = 0;
  int ipcCanReadCacheHits = 0;

  /// `find_assets` RPCs.
  int ipcFindAssetsCalls = 0;
  int ipcFindAssetsUs = 0;

  /// Analyzer byte-store traffic through the shared store.
  int byteStoreGets = 0;
  int byteStoreGetUs = 0;
  int byteStoreHits = 0;
  int byteStorePuts = 0;
  int byteStorePutUs = 0;
  int byteStorePutBytes = 0;

  /// First-call wall time of each `Resolver` method, keyed by method name.
  final Map<String, int> resolverFirstCallUs = <String, int>{};

  /// Total time spent inside each `Resolver` method, keyed by method name.
  final Map<String, int> resolverCallUs = <String, int>{};

  /// Number of libraries streamed through `Resolver.libraries`.
  int librariesCount = 0;

  /// Wall time to enumerate `Resolver.libraries` fully.
  int librariesStreamUs = 0;

  /// build_runner `TimedActivity` buckets (resolve/analyze/build/read/write/
  /// track) attributed to this action, filled from `buildLog.activities`.
  final Map<String, int> activityUs = <String, int>{};

  void beginAction() {
    cycleGraphWalkUs = 0;
    cycleGraphFileLoads = 0;
    depParseCacheHits = 0;
    depParseCacheMisses = 0;
    depParseCacheUs = 0;
    depReadPhasedUs = 0;
    depParseUs = 0;
    applyPendingChangesUs = 0;
    filesystemPhaseSyncUs = 0;
    ipcReadCalls = 0;
    ipcReadUs = 0;
    ipcReadBytes = 0;
    ipcReadCacheHits = 0;
    ipcCanReadCalls = 0;
    ipcCanReadUs = 0;
    ipcCanReadCacheHits = 0;
    ipcFindAssetsCalls = 0;
    ipcFindAssetsUs = 0;
    byteStoreGets = 0;
    byteStoreGetUs = 0;
    byteStoreHits = 0;
    byteStorePuts = 0;
    byteStorePutUs = 0;
    byteStorePutBytes = 0;
    resolverFirstCallUs.clear();
    resolverCallUs.clear();
    librariesCount = 0;
    librariesStreamUs = 0;
    activityUs.clear();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'cycle_graph_walk_us': cycleGraphWalkUs,
    'cycle_graph_file_loads': cycleGraphFileLoads,
    'dep_parse_cache_hits': depParseCacheHits,
    'dep_parse_cache_misses': depParseCacheMisses,
    'dep_parse_cache_us': depParseCacheUs,
    'dep_read_phased_us': depReadPhasedUs,
    'dep_parse_us': depParseUs,
    'apply_pending_changes_us': applyPendingChangesUs,
    'filesystem_phase_sync_us': filesystemPhaseSyncUs,
    'ipc_read_calls': ipcReadCalls,
    'ipc_read_us': ipcReadUs,
    'ipc_read_bytes': ipcReadBytes,
    'ipc_read_cache_hits': ipcReadCacheHits,
    'ipc_can_read_calls': ipcCanReadCalls,
    'ipc_can_read_us': ipcCanReadUs,
    'ipc_can_read_cache_hits': ipcCanReadCacheHits,
    'ipc_find_assets_calls': ipcFindAssetsCalls,
    'ipc_find_assets_us': ipcFindAssetsUs,
    'byte_store_gets': byteStoreGets,
    'byte_store_get_us': byteStoreGetUs,
    'byte_store_hits': byteStoreHits,
    'byte_store_puts': byteStorePuts,
    'byte_store_put_us': byteStorePutUs,
    'byte_store_put_bytes': byteStorePutBytes,
    'resolver_first_call_us': resolverFirstCallUs,
    'resolver_call_us': resolverCallUs,
    'libraries_count': librariesCount,
    'libraries_stream_us': librariesStreamUs,
    'activity_us': activityUs,
  };
}

/// The process-wide sink; see [ResolverActionMetrics].
final resolverActionMetrics = ResolverActionMetrics();
