# Architecture Decision Records

These ADRs record durable compatibility, correctness, protocol, performance,
and distribution decisions. They are a release baseline, not a commit history.
Implementation details belong in source comments, the worker protocol, or
focused guides.

Add or replace an ADR when a compatibility or architectural boundary changes.
Benchmarks and mechanical refactors do not need one.

## Decisions

| ADR | Decision |
| --- | --- |
| [0001](0001-architecture-and-compatibility-boundary.md) | Rust frontend, Dart worker, and compatibility boundary |
| [0002](0002-incremental-state-and-transactional-commit.md) | Incremental state, dependency tracking, and transactional commits |
| [0003](0003-worker-ipc-and-lifecycle.md) | Worker IPC, binary capabilities, and lifecycle |
| [0004](0004-generic-manifest-and-target-semantics.md) | Generic manifest path and target semantics |
| [0005](0005-performance-and-validation-policy.md) | Performance policy, worker parallelism, and validation |
| [0006](0006-distribution-and-release-artifacts.md) | Public package, launcher, and native release artifacts |
| [0007](0007-sdk-and-dependency-compatibility-window.md) | Supported Dart SDK and dependency compatibility window |
| [0008](0008-runtime-expected-output-mappings.md) | Runtime expected-output mappings and conservative fallback |
| [0009](0009-shared-analyzer-byte-store.md) | Shared analyzer byte store across workers and builds |
| [0010](0010-path-based-asset-reads.md) | Path-based asset reads |
| [0011](0011-analysis-prewarm-in-aot-prewarm.md) | Analysis prewarm; command renamed to prewarm by ADR 0030 |
| [0012](0012-machine-wide-cache.md) | Machine-wide cache for worker AOT and analyzer byte store |
| [0013](0013-part-directive-prefilter.md) | part directive pre-filter |
| [0014](0014-manifest-probe-caching-and-compile-overlap.md) | Factory-probe caching and compile overlap |
| [0015](0015-manifest-generator-kernel-cache.md) | Compiled manifest generator cache and source fallback |
| [0016](0016-early-worker-catalog.md) | Builder selection before cold generator compilation |
| [0017](0017-manifest-window-analysis-prewarm.md) | Manifest-window analysis prewarm and SDK summary auto-prewarm |
| [0018](0018-cross-workspace-cold-start-sharing.md) | Cross-workspace kernel reuse and shared SDK summary lock |
| [0019](0019-directive-deps-parse-cache.md) | Content-keyed directive-deps cache |
| [0020](0020-batch-dep-read-resolve.md) | Batched dependency reads for the cycle walk |
| [0021](0021-packed-shared-cache-stores.md) | Packed shared stores and digest-keyed dep lookups |
| [0022](0022-packed-cache-write-and-migration-lifecycle.md) | Packed writes and legacy-entry cleanup |
| [0023](0023-manifest-trigger-parser-isolation.md) | Trigger parser isolation |
| [0024](0024-cold-analysis-single-flight.md) | Single-flight cold analysis |
| [0025](0025-packed-cache-publication-without-fsync.md) | Packed cache publication policy |
| [0026](0026-byte-store-publication-index.md) | Byte-store publication index |
| [0027](0027-reset-overlay-blob-transport.md) | Overlay blob transport |
| [0028](0028-setup-time-prewarm-command.md) | Setup-time prewarm and single-flight AOT compiles |
| [0029](0029-cli-routing-and-fallback.md) | CLI routing, stock fallback, and process lifecycle |
| [0030](0030-compatibility-cleanup-and-disposable-state.md) | Compatibility cleanup and disposable state |
| [0031](0031-native-build-settings.md) | Native configuration and settings invalidation |
| [0032](0032-native-build-filter-demand-and-output-state.md) | Filter demand, output state, and conservative fallback |
| [0033](0033-filtered-demand-scheduler.md) | Parallel filtered demand coordination and lazy worker startup |
| [0035](0035-package-source-identity.md) | Package source sets, nested asset identities and watch boundary |

The worker wire contract is in [protocol v1](../../protocol/v1.md). Release
artifacts and launcher behavior are in
[launcher-and-release.md](../launcher-and-release.md).
