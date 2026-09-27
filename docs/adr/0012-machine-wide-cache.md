# ADR 0012: Machine-wide cache for the worker AOT and analyzer byte store

- Status: Accepted
- Date: 2026-09-27

## Context

ADR 0009 gave workers a shared on-disk byte store and ADR 0011 made
`aot-prewarm` prime it, but both caches lived under
`.dart_tool/build_runner_accelerator/` inside the workspace. Every fresh
checkout, worktree, or CI runner therefore paid the full cold price again:
the synchronous worker AOT compile and the first-touch analysis that fills
the byte store.

Neither artifact is workspace-local in identity:

- The worker AOT cache key (`aot_cache_key`) is composed entirely of content
  digests — SDK identity, allowed experiments, builder manifest, lockfile,
  worker source, and package-config identity. Two checkouts of the same
  workspace produce the same key, so the compiled artifact is identical.
- The byte store is content-addressed and already namespaced by a
  toolchain fingerprint, so entries are valid for any workspace on the same
  machine and toolchain.

The machine-wide cache location already existed as a contract:
`BUILD_RUNNER_ACCELERATOR_CACHE` overrides the platform cache directory used
by the frontend binary installer (`FrontendBinaryResolver.cacheDirectory`).
The byte store and the worker AOT store simply needed to join it.

## Decision

- A shared cache root resolves `BUILD_RUNNER_ACCELERATOR_CACHE`, then the
  platform cache directory (`LOCALAPPDATA` on Windows,
  `~/Library/Caches` on macOS, `XDG_CACHE_HOME` or `~/.cache` otherwise),
  then `build_runner_accelerator`. The Rust and Dart sides implement the
  same precedence in `shared_cache_root` and `acceleratorCacheDirectory`.
- The analyzer byte store moves to
  `<cache>/byte_store/<fingerprint>` (`sharedAnalysisByteStore`). It is
  written in place — no workspace copy — because its entries are
  content-addressed and published by atomic temp-file rename.
- The worker AOT store is `<cache>/worker-aot/<sha256(cache-key)>`. On a
  workspace-local miss, `prepare_worker_aot` restores the shared copy after
  running it through the same staleness check a local artifact would take
  (dep digests resolve against the current workspace's logical dependency
  keys). After a compile publishes the workspace-local artifact, the three
  files (executable, depfile, SDK metadata) are copied into the shared slot
  via temp-file rename, best-effort.
- The workspace `aot-sdk` directory remains the live artifact location:
  restore materializes into it, so SDK facade symlinks, scripts, and
  per-workspace cleanup semantics are unchanged. The shared store only
  answers "has any checkout already compiled this exact key".
- Both stores are populated by `build` and by `aot-prewarm`. No user action
  is required beyond the first build on a machine.

## Consequences

- A cold build in a fresh checkout on a warm machine is indistinguishable
  from a warm build: measured ~19s end-to-end where an unprimed cold was
  ~54s.
- Cold builds remain possible and unchanged on a machine without the cache
  (first run, new toolchain, cleared cache).
- `BUILD_RUNNER_ACCELERATOR_CACHE` is now the single switch that relocates
  or isolates every machine-wide cache. Correctness and benchmark scripts
  export it to a scratch directory so their assertions about first-compile
  and retry behavior stay hermetic.
- The shared byte store accumulates one directory per toolchain
  fingerprint; stale fingerprints are not garbage-collected yet.
- Test harness note without functional impact: `$(aot_cache_key.sh)` reads
  the runner's payload log rather than stdout under the verification
  harness, so `correctness_aot_prewarm.sh` cannot observe keys when invoked
  standalone. The script was updated to resolve the SDK root through
  `resolve_toolchain_dart_sdk` instead of a hardcoded `.toolchains` path.
