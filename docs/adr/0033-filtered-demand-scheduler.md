# ADR 0033: Parallel filtered demand and lazy worker startup

- Status: Accepted
- Date: 2026-10-11
- Amends [ADR 0032](0032-native-build-filter-demand-and-output-state.md).

## Context

Filtered builds previously ran every selected root and its recursive producer
demands on one resident Dart worker. This preserved nested asset-request order,
but ignored `--jobs` for independent selected roots and started a worker even
when all requested actions could be reused.

Parallel execution must still discover dependencies from actual RPC requests.
The previous graph is evidence for reuse decisions; it cannot predict new
`read`, `canRead`, `findAssets`, or resolver requests. Multiple workers must
also share one producer result and one transaction view for all sibling
outputs. A failure or worker exit must wake dependent waiters and retain the
existing all-success commit boundary.

## Decision

Use one filtered-demand path in both a no-worker reuse probe and worker
execution. The probe follows the same primary-input, ordered stock-input, glob,
and resolver checks as execution. It records clean actions and their demanded
keys, and identifies the selected roots whose demand reaches dirty work. A
no-op filtered build commits without resolving a worker artifact, starting a
Dart process, or initializing Dart workers. Only dirty roots reach the worker
pool, so a one-root dirty build does not expand to the full `--jobs` count.
Filtered watch creates a deferred pool descriptor and starts it only when a
dirty root needs execution. Ordinary watch and unfiltered scheduling keep their
existing startup behavior.

Dirty selected roots run on one worker by default. An explicit `--jobs N` opts
into up to N workers, capped by the number of dirty roots, when the shared
analyzer byte store is enabled. This fixed conservative default suits
lightweight builders; it is not a workload-learning heuristic. With the byte
store disabled, filtered execution stays on one worker even when `--jobs` is
set because resolver state may be process-local. Every worker is initialized
and reset with the transaction's starting overlay before any root runs. Actual
asset RPCs discover dependencies recursively; `resolve_assets` remains a
prefetch refusal in filtered mode, so generated assets are served only after
their producer completes.

Unfiltered execution retains the machine-based worker default.
`BUILD_RUNNER_ACCELERATOR_RESOLVER_CAP` continues to control only
resolver-backed batches in the unfiltered scheduler; it does not cap filtered
root workers.

A transaction coordinator claims each action once, and stores immutable
completion records for its complete output set. A record distinguishes bytes,
missing siblings, and outputs already on disk. Workers apply the whole set to
their local overlays before continuing. The coordinator's wait graph tracks
both nested action ownership and cross-worker waits. No IPC or filesystem work
holds its mutex. A wait cycle, action error, IPC failure, panic, or owner drop
latches a transaction failure and wakes all waiters.

The filtered build commits outputs and graph state only after all worker roots
and recursive demands succeed. A builder or worker failure before commit leaves
the previously successful native outputs and graph in place; interruption or
I/O failure during commit does not have a crash rollback guarantee (ADR 0002).
The unfiltered scheduler and
stock fallback contract are unchanged.

Filtered watch keeps source and existing glob snapshot evidence from the start
of each build. Generated outputs use the post-commit snapshot. An edit, add, or
delete that arrives while a builder is active therefore remains visible to the
queued watch event instead of being recorded as already incorporated.
For an external source first read during a build, the transaction coordinator
shares its first observed bytes across workers. This matches stock build-step
source caching and gives `canRead` and `read` one stable view throughout the
build. The initial read and identity-digest calculation add cold external
dependency I/O; the bytes are cached in memory when they fit the RPC frame and
spooled to a temporary file when they do not.

## Consequences

Independent dirty roots can use `--jobs`; roots sharing a producer reuse one
published result. Runtime dependencies added by a builder do not need to be
present in the previous graph. A dependency discovered only after a reused
candidate proves dirty prevents the probe from seeding its parent as clean;
the actual worker can still reuse that parent if the completed dependency did
not change its observable inputs or glob membership.

Unknown external source snapshots require a Rust read and identity digest on
first demand. Simultaneous first requests may each perform a speculative read
before the coordinator publishes one shared result. Cached bytes consume
memory up to the RPC frame limit and use a temporary spool above it; large
resolver or package inputs were not part of the fixture performance
measurements.

Parallelism is at selected-root granularity; nested work within one root still
uses that root's worker stack, while other selected roots can make progress.
Existing resolver prefetch, optional-builder, post-process, trigger-only, and
zero-output fallback boundaries remain unchanged.

The filtered worker default is intentionally one because lightweight builders
can be slower with several workers: each Dart process adds startup work and
analyzer memory, and the measured lightweight fixture favored one worker for
dirty work. This fixed default is not a learned or workload-adaptive policy.
Explicit `--jobs` enables overlap for larger independent tasks. Lazy startup
still avoids worker cost on no-op builds.
