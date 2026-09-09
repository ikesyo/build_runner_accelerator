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

The wire-level details for ADR 0003 live in
[protocol/v1.md](../../protocol/v1.md). Release matrix and cache details for
ADR 0006 live in
[doc/launcher-and-release.md](../../doc/launcher-and-release.md).
