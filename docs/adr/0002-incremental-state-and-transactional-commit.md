# ADR 0002: Incremental state and transactional commit

Stock fallback and frontend-mode statements below are superseded by
[ADR 0036](0036-native-only-execution.md) for 0.14.0. Unsupported requests now fail
explicitly; native correctness and supported-subset boundaries remain.


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
builder/worker failure before commit leaves the last committed output and graph
state intact. [ADR 0040](0040-interrupted-commit-recovery.md) adds an undo journal
for I/O errors and process interruption during publication. Output deletions and
individual atomic writes still precede graph publication; recovery restores the
previous outputs and graph before reuse. This is recoverable publication, not a
simultaneously atomic filesystem snapshot or a power-loss durability guarantee.

Native build and watch commands acquire a nonblocking OS file lock under
`.dart_tool/build_runner_accelerator/.workspace.lock` before manifest generation
and hold it for the entire command, including late stock fallback. A second
native command, even with another filter or auto mode, reports an error instead
of starting a competing fallback. The OS releases ownership on process exit;
the file is never unlinked. Prewarm does not write outputs or graph and does
not take this lock. Direct stock commands and dart-mode commands do not share
the native lock, and an early fallback that bypasses the native binary does
not acquire it; callers must serialize those against native build/watch too.
Different workspaces may run concurrently. The in-process worker coordinator
is not a substitute for this command-level writer exclusion.

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

