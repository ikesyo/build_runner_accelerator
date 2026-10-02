# ADR 0020: Batch dep-read resolution for the library cycle walk

- Status: Accepted
- Date: 2026-10-02

## Context

ADR 0019 eliminated the re-parse half of the per-worker
`LibraryCycleGraphLoader` walk, leaving `dep_read_phased_us` (~0.6s on the
~880-file riverpod fixture) as the residual cost. Per dep file, the walk's
`readPhased` performs a `can_read` asset RPC plus a `read` asset RPC whose
path answer the worker then reads sequentially with
`File(path).readAsBytes()`. RPC round-trips account for ~0.17s; the
sequential async file reads (stream machinery per file) account for ~0.24s;
UTF-8 decode plus `updateSourceContent`/`_onUpdateContent` bookkeeping make
up the rest. The worker's `RpcSession` is strictly sequential — a single
`FrameReader`/`StreamIterator` — so per-asset RPCs cannot be pipelined;
only a batch operation can remove the round-trips.

The read half remains semantically required: `readPhased` → `contentOf` is
the only channel feeding dep-file bytes into the analyzer's in-memory
filesystem (`buildState.updateSourceContent` + the content listener), and
`observedReads`/`readCache`/`readableCache` drive input tracking and
invalidation (see ADR 0019). Any batching must land bytes through the same
calls and leave those structures identical to the sequential path.

## Decision

- Protocol v1 gains a `resolve_assets` asset operation: the batch form of
  `read`. Each requested asset is resolved under the same rules — blocked
  or missing → `not_found`, in-memory overlay hit → `bytes` (offset/length
  into a `BRAB` payload), disk-backed → `path` — so a positive entry is
  also the `can_read == true` answer for that asset.
- `_CachingAssetDepsLoader.load` prefetches each complete result's deps:
  `RemoteBuilderFilesystem.prefetchDepReads` filters out assets served by
  `buildState.contentOf` (committed outputs), then
  `RemoteAssetReaderWriter.prefetchAssets` issues one `resolve_assets`
  call per dep frontier and fills `readCache`/`readableCache` with the
  resolved paths (read synchronously) and overlay bytes. The walk's
  subsequent `canRead`/`readAsBytes` calls hit the warmed caches and flow
  through `contentOf` → `updateSourceContent` → `_onUpdateContent`
  unchanged, so every `readPhased` side effect is preserved.
- Only positive resolutions are ever cached, and only under the same
  conditions the sequential path caches them. Candidates are filtered on
  the worker side (per-action `outputs`, `blockedAssets`, `primaryInput`,
  already-cached ids); `not_found`, malformed entries, RPC failures, and
  failed file reads leave the asset uncached so the sequential path —
  including its exceptions — replays unchanged. `observedReads` is filled
  only by the real calls during the walk, exactly as before.
- `BUILD_RUNNER_ACCELERATOR_DEP_PREFETCH=0` disables prefetching.
  Batch/prefetch traffic (`ipc_resolve_assets_calls/us`,
  `dep_prefetch_assets`, `dep_prefetch_us`) is reported in the per-action
  metrics block, and `resolve_assets_requests`/`resolve_assets_results`
  in the Rust pool metrics.

## Consequences

- On the riverpod fixture the dep walk drops from ~0.79s to ~0.53s per
  worker: `dep_read_phased_us` ~0.60s → ~0.29s, `can_read` RPCs 881 → 1,
  `read` RPCs 885 → 5, replaced by ~240 `resolve_assets` calls (~0.04s)
  plus ~0.06s of synchronous prefetch reads. Whole-build wall time drops
  ~17–24% at jobs 1/2/4.
- Path answers keep the ADR 0010 invariant — disk bytes are still read by
  the worker, never piped through IPC — while overlay bytes ride the same
  `BRAB` frame a single `read` would use. Payload size is bounded by each
  dep frontier, far below the 256 MiB frame cap.
- The residual walk cost is now dominated by per-file bookkeeping
  (`updateSourceContent`, `_onUpdateContent`, `PhasedValue`/`ExpiringValue`
  allocation, decode) which is required work, not IPC; further cuts would
  need batching inside the analyzer filesystem, a separate boundary.
- Prefetched `readCache` entries are sublist views of the `BRAB` frame for
  overlay assets and fresh `readAsBytesSync` results for disk assets —
  identical content to what the sequential path would cache, with the same
  freeze semantics under the build's file immutability assumption.
- Correctness fixtures (`correctness_riverpod.sh`,
  `correctness_freezed.sh`) remain byte-identical to stock; with the env
  opt-out the request stream is byte-for-byte the pre-change sequence
  (`resolve_assets_requests=0`).
