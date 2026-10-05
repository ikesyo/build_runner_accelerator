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

  /// Detailed path diagnostics are kept out of ordinary timing runs.
  final bool traceEnabled =
      Platform.environment['BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE'] == '1';
  final Set<String> fileContentPaths = <String>{};
  final List<String> canReadAssets = <String>[];
  final Set<String> byteStoreMissKeys = <String>{};

  /// Time acquiring/checking the cold-analysis gate before linking.
  int analysisStartupWaitUs = 0;

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

  /// Content acquisition, conversion/hash, and notification are separate
  /// boundaries inside depReadPhasedUs. Prefetch happens outside that timer.
  int depVisibilityUs = 0;
  int depContentCalls = 0;
  int depContentUs = 0;
  int depContentUpdateUs = 0;
  int depContentDecodeHashUs = 0;
  int depContentSnapshotBytes = 0;
  final List<Map<String, Object?>> depLoads = [];

  /// `parseString` for dep files that miss the cache.
  int depParseUs = 0;

  /// Conditional directive collection, separate from cycle-graph parsing.
  int resolverReadsReadUs = 0;
  int resolverReadsDigestUs = 0;
  int resolverReadsDigestComputations = 0;
  int resolverReadsDigestReuses = 0;
  int resolverReadsCacheUs = 0;
  int resolverReadsDecodeUs = 0;
  int resolverReadsParseUs = 0;
  int resolverReadsResolveUs = 0;
  int resolverReadsMemoryHits = 0;
  int resolverReadsPersistentHits = 0;
  int resolverReadsPersistentMisses = 0;
  int resolverReadsParses = 0;

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

  /// Batched `resolve_assets` RPCs issued by dep-read prefetching.
  int ipcResolveAssetsCalls = 0;
  int ipcResolveAssetsUs = 0;

  /// Assets whose read/readable caches were warmed by a batch resolve, and
  /// total prefetch time inside [RemoteAssetReaderWriter.prefetchAssets].
  int depPrefetchAssets = 0;
  int depPrefetchUs = 0;

  /// Analyzer byte-store traffic through the shared store, split by key
  /// suffix: `.unlinked2` summaries, `.linked` element-model bundles, and
  /// everything else.
  int byteStoreGets = 0;
  int byteStoreGetUs = 0;
  int byteStoreHits = 0;
  int byteStorePuts = 0;
  int byteStorePutUs = 0;
  int byteStorePutBytes = 0;
  int byteStoreGetsUnlinked = 0;
  int byteStoreGetUnlinkedUs = 0;
  int byteStoreGetsLinked = 0;
  int byteStoreGetLinkedUs = 0;
  int byteStoreGetsOther = 0;
  int byteStoreGetOtherUs = 0;

  /// `FileContentCache.get` traffic feeding `FileState.refresh` (the `_data`
  /// content reads inside `libraryFor`/`updateDriver`).
  int fileContentGets = 0;
  int fileContentGetUs = 0;

  /// First-call wall time of each `Resolver` method, keyed by method name.
  final Map<String, int> resolverFirstCallUs = <String, int>{};

  /// Total time spent inside each `Resolver` method, keyed by method name.
  final Map<String, int> resolverCallUs = <String, int>{};
  final Map<String, int> resolverCallCounts = <String, int>{};

  /// Number of libraries streamed through `Resolver.libraries`.
  int librariesCount = 0;

  /// Wall time to enumerate `Resolver.libraries` fully.
  int librariesStreamUs = 0;

  void beginAction() {
    fileContentPaths.clear();
    canReadAssets.clear();
    byteStoreMissKeys.clear();
    analysisStartupWaitUs = 0;
    cycleGraphWalkUs = 0;
    cycleGraphFileLoads = 0;
    depParseCacheHits = 0;
    depParseCacheMisses = 0;
    depParseCacheUs = 0;
    depReadPhasedUs = 0;
    depVisibilityUs = 0;
    depContentCalls = 0;
    depContentUs = 0;
    depContentUpdateUs = 0;
    depContentDecodeHashUs = 0;
    depContentSnapshotBytes = 0;
    depLoads.clear();
    depParseUs = 0;
    resolverReadsReadUs = 0;
    resolverReadsDigestUs = 0;
    resolverReadsDigestComputations = 0;
    resolverReadsDigestReuses = 0;
    resolverReadsCacheUs = 0;
    resolverReadsDecodeUs = 0;
    resolverReadsParseUs = 0;
    resolverReadsResolveUs = 0;
    resolverReadsMemoryHits = 0;
    resolverReadsPersistentHits = 0;
    resolverReadsPersistentMisses = 0;
    resolverReadsParses = 0;

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
    ipcResolveAssetsCalls = 0;
    ipcResolveAssetsUs = 0;
    depPrefetchAssets = 0;
    depPrefetchUs = 0;
    byteStoreGets = 0;
    byteStoreGetUs = 0;
    byteStoreHits = 0;
    byteStorePuts = 0;
    byteStorePutUs = 0;
    byteStorePutBytes = 0;
    byteStoreGetsUnlinked = 0;
    byteStoreGetUnlinkedUs = 0;
    byteStoreGetsLinked = 0;
    byteStoreGetLinkedUs = 0;
    byteStoreGetsOther = 0;
    byteStoreGetOtherUs = 0;
    fileContentGets = 0;
    fileContentGetUs = 0;
    resolverFirstCallUs.clear();
    resolverCallUs.clear();
    resolverCallCounts.clear();
    librariesCount = 0;
    librariesStreamUs = 0;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'worker_pid': pid,
    'worker_rss_bytes': ProcessInfo.currentRss,
    if (traceEnabled) 'file_content_paths': fileContentPaths.toList()..sort(),
    if (traceEnabled) 'can_read_assets': canReadAssets,
    if (traceEnabled)
      'byte_store_miss_keys': byteStoreMissKeys.toList()..sort(),
    if (traceEnabled && Platform.isLinux) 'worker_cpu_ticks': _cpuTicks(),
    'analysis_startup_wait_us': analysisStartupWaitUs,
    'cycle_graph_walk_us': cycleGraphWalkUs,
    'cycle_graph_file_loads': cycleGraphFileLoads,
    'dep_parse_cache_hits': depParseCacheHits,
    'dep_parse_cache_misses': depParseCacheMisses,
    'dep_parse_cache_us': depParseCacheUs,
    'dep_read_phased_us': depReadPhasedUs,
    'dep_visibility_us': depVisibilityUs,
    'dep_content_calls': depContentCalls,
    'dep_content_us': depContentUs,
    'dep_content_update_us': depContentUpdateUs,
    'dep_content_decode_hash_us': depContentDecodeHashUs,
    'dep_content_snapshot_bytes': depContentSnapshotBytes,
    if (traceEnabled) 'dep_loads': depLoads,

    'dep_parse_us': depParseUs,
    'resolver_reads_read_us': resolverReadsReadUs,
    'resolver_reads_digest_us': resolverReadsDigestUs,
    'resolver_reads_digest_computations': resolverReadsDigestComputations,
    'resolver_reads_digest_reuses': resolverReadsDigestReuses,
    'resolver_reads_cache_us': resolverReadsCacheUs,
    'resolver_reads_decode_us': resolverReadsDecodeUs,
    'resolver_reads_parse_us': resolverReadsParseUs,
    'resolver_reads_resolve_us': resolverReadsResolveUs,
    'resolver_reads_memory_hits': resolverReadsMemoryHits,
    'resolver_reads_persistent_hits': resolverReadsPersistentHits,
    'resolver_reads_persistent_misses': resolverReadsPersistentMisses,
    'resolver_reads_parses': resolverReadsParses,

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
    'ipc_resolve_assets_calls': ipcResolveAssetsCalls,
    'ipc_resolve_assets_us': ipcResolveAssetsUs,
    'dep_prefetch_assets': depPrefetchAssets,
    'dep_prefetch_us': depPrefetchUs,
    'byte_store_gets': byteStoreGets,
    'byte_store_get_us': byteStoreGetUs,
    'byte_store_hits': byteStoreHits,
    'byte_store_puts': byteStorePuts,
    'byte_store_put_us': byteStorePutUs,
    'byte_store_put_bytes': byteStorePutBytes,
    'byte_store_gets_unlinked': byteStoreGetsUnlinked,
    'byte_store_get_unlinked_us': byteStoreGetUnlinkedUs,
    'byte_store_gets_linked': byteStoreGetsLinked,
    'byte_store_get_linked_us': byteStoreGetLinkedUs,
    'byte_store_gets_other': byteStoreGetsOther,
    'byte_store_get_other_us': byteStoreGetOtherUs,
    'file_content_gets': fileContentGets,
    'file_content_get_us': fileContentGetUs,
    'resolver_first_call_us': resolverFirstCallUs,
    'resolver_call_us': resolverCallUs,
    'resolver_call_counts': resolverCallCounts,
    'libraries_count': librariesCount,
    'libraries_stream_us': librariesStreamUs,
  };

  /// Linux user + system CPU ticks, cumulative since worker start. Consumers
  /// must record `getconf CLK_TCK`; this diagnostic is not a wall-time timer.
  int? _cpuTicks() {
    try {
      final stat = File('/proc/self/stat').readAsStringSync();
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      return int.parse(fields[11]) + int.parse(fields[12]);
    } on Object {
      return null;
    }
  }
}

/// The process-wide sink; see [ResolverActionMetrics].
final resolverActionMetrics = ResolverActionMetrics();
