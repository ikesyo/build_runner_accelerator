# ADR 0002: Incremental state and transactional commit

- Status: Accepted
- Date: 2026-09-07

## Context

An accelerator is useful only if its incremental behavior is trustworthy.
build_runner actions can depend on ordinary reads, resolver reads, glob
queries, missing assets, generated cache outputs, and source outputs from
earlier phases. A worker failure must not leave a half-updated graph or output
tree.

## Decision

The Rust frontend maintains a private, versioned workspace state containing:

- a filesystem snapshot and digests for relevant assets;
- an action graph keyed by the resolved builder and target configuration;
- observed asset reads, resolver reads, glob queries, and missing-asset
  dependencies;
- pending generated outputs and deletions in an overlay;
- enough metadata to detect no-op, deletion, rename, and dependency changes.

Dirty propagation uses the recorded observations and the resolved phase order.
The overlay is visible to later phases according to the build contract, while
same-phase outputs remain hidden from the action that owns them. Rust commits
outputs, deletions, and the graph only after every dirty action succeeds. A
failure leaves the last committed output and graph state intact.

The graph format is an implementation-owned versioned binary under
.dart_tool/build_runner_accelerator/. It is not build-runner's private
AssetGraph format. Unchanged no-op builds do not rewrite the graph.

## Consequences

Correctness is defined by state transitions, not only by clean-build output.
Delete, rename, dependency, glob, failure-recovery, and watch cases are part of
the validation contract. The private graph can evolve independently, but it
must be invalidated or migrated when its meaning changes.

The overlay and all-success commit add coordination work, but they provide a
clear failure boundary and let later phases observe committed-equivalent
source outputs without exposing partial results.

## Alternatives considered

- Commit each action immediately: rejected because a later failure would leave
  inconsistent outputs and graph state.
- Track only direct file reads: rejected because resolver, glob, and missing
  assets also affect action validity.
- Reuse build-runner's private graph bytes: rejected because it is not a stable
  public compatibility boundary.

