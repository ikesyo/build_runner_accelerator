# ADR 0009: Shared analyzer byte store across workers and builds

- Status: Accepted
- Date: 2026-09-26

## Context

The stock frontend runs the generated build script as one process, so every
builder and phase shares a single analyzer `AnalysisContextCollection` in
memory. The Rust frontend runs several worker processes, each constructing its
own driver, so the same package-resolution work is paid per worker and again
after each phase commit resets the resolver. On a large workspace this
duplicated analysis is the dominant clean-build gap versus stock.

The analyzer's `analysisDriver` accepts a `ByteStore`. The default
`MemoryByteStore` is process-local; `FileByteStore` persists resolved units
and element models addressed by content- and version-derived keys.

## Decision

- Construct each worker's analysis driver with a
  `MemoryCachingByteStore(FileByteStore(dir))` under
  `.dart_tool/build_runner_accelerator/byte_store/<fingerprint>`. The
  directory is shared by every worker in the build and reused across builds.
- `<fingerprint>` is the truncated SHA-256 of the SDK summary bytes, the
  enabled experiments, and the resolved analyzer package root. Byte-store keys
  do not include SDK or analyzer identity, so the fingerprint keeps entries
  built by a different toolchain unreachable rather than merely stale.
- Stale keys are never read back: they only occupy disk. We do not use
  `EvictingFileByteStore` because its eviction isolate owns cache cleanup in
  one process, which conflicts with concurrent independent workers.
- `BUILD_RUNNER_ACCELERATOR_BYTE_STORE=0` (also `false`/`off`) restores the
  previous process-local `MemoryByteStore` behavior for debugging and A/B
  measurement.

## Consequences

- Clean warm-build execution drops to roughly stock single-process time on the
  reference workspace (worker count unchanged; the resolver work is reused
  instead of duplicated).
- Concurrent writers are safe: `FileByteStore` writes to a pid-suffixed temp
  name and atomically renames, so identical keys written by two workers
  converge on the same bytes.
- The byte-store directory is not part of the incremental graph. Deleting
  `.dart_tool/build_runner_accelerator/{graph,cache}` keeps it; deleting
  `byte_store/` forfeits the warm benefit without affecting correctness.
- Output compatibility is unchanged: the store only changes how analysis
  results are cached, not what is resolved.

## Alternatives considered

- Dedicated resolver process serving other workers over IPC: rejected for now
  because it adds a new protocol surface and failure mode; the byte store
  reuses the analyzer's own format with no protocol change.
- EvictingFileByteStore with automatic eviction: rejected because eviction is
  owned by a single managing process while workers here are independent.
