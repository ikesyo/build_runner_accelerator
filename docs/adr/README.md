# Architecture Decision Records

This directory is the release-oriented decision index for
build_runner_accelerator. It was consolidated on 2026-09-07: the previous
commit-level experiment log was intentionally reduced to the durable
architecture and distribution boundaries. Detailed implementation history
remains available in Git, but it is not part of the public decision index.

An ADR should describe one durable boundary that affects compatibility,
protocol, correctness, performance policy, or distribution. A benchmark result,
mechanical refactor, or isolated implementation step does not need its own
ADR. When a decision changes, add a new ADR that explains the replacement
boundary rather than restoring commit-level history.

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
| [0011](0011-analysis-prewarm-in-aot-prewarm.md) | Analysis prewarm in `aot-prewarm` |
| [0012](0012-machine-wide-cache.md) | Machine-wide cache for the worker AOT and analyzer byte store |
| [0013](0013-part-directive-prefilter.md) | `part` directive pre-filter for part-family builders |
| [0014](0014-manifest-probe-caching-and-compile-overlap.md) | Factory-probe caching and compile overlap in manifest generation |
| [0015](0015-manifest-generator-kernel-cache.md) | Compiled manifest generator cache and source fallback |
| [0016](0016-early-worker-catalog.md) | Shared builder selection before cold generator compilation |
| [0017](0017-manifest-window-analysis-prewarm.md) | Manifest-window analysis prewarm and SDK summary auto-prewarm |
| [0018](0018-cross-workspace-cold-start-sharing.md) | Cross-workspace manifest kernel reuse and shared SDK summary lock |
| [0019](0019-directive-deps-parse-cache.md) | Content-keyed directive-deps parse cache for the library cycle walk |
| [0020](0020-batch-dep-read-resolve.md) | Batch dep-read resolution for the library cycle walk |
| [0021](0021-packed-shared-cache-stores.md) | Packed shared cache stores and digest-keyed dep lookups |
| [0022](0022-packed-cache-write-and-migration-lifecycle.md) | Deduplicated packed writes and deletion of migrated legacy entries |
| [0023](0023-manifest-trigger-parser-isolation.md) | Official trigger parsing in the compiled worker keeps Analyzer out of the manifest generator |

The wire-level details for ADR 0003 live in
[protocol/v1.md](../../protocol/v1.md). Release matrix and cache details for
ADR 0006 live in
[launcher-and-release.md](../launcher-and-release.md).
