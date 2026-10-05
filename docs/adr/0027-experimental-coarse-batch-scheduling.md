# ADR 0027: Experimental coarse batch scheduling

- Status: Proposed (opt-in experiment; fixed count splitting remains the default)
- Date: 2026-10-05

## Context

PR #89 application wall traces show a substantial last-worker tail in a
homogeneous phase. Equal request counts do not imply equal builder work.
Changing worker participation or resetting resident Analyzer state would mix
separate performance hypotheses. Arbitrary stateful builders can also expose
changes to worker membership and per-worker execution order.

## Decision under evaluation

Keep fixed balanced contiguous ranges by default. Allow explicit experiments
through `BUILD_RUNNER_ACCELERATOR_BATCH_SCHEDULER=tail`, `tail2` or `queue` on the
normal-builder immutable-overlay path only. Unknown/unset values use fixed ranges.
Single-worker calls and phases below 32 requests per participating worker
retain the original batch. Resolver classification, participant cap, startup,
reset and shared-cache policy remain unchanged.

Split each original range into a half followed by two quarters. `tail`
reserves the original first half for its original worker before threads start.
Workers consume their own queue from the front; after exhausting it, they
claim an unstarted donor tail from the back. `queue` instead claims pieces
from a common ordered queue; it is the lower-affinity comparison control.
Claims are synchronized only while taking a range. Each participant holds
one resident worker for the whole dispatch and executes whole protocol batches
sequentially. No action-granularity RPC, historical cost model or persistent
scheduler cache is added.

Each sub-batch retains the original phase visibility and deleted overlay.
WorkerClient validates response count, batch ID and local item IDs before
pool integration. Results are placed back in original request order, with
original count-partition local item IDs restored. All threads join before
returning results; protocol errors return no partial result vector. Builder
errors retain their original request position and existing all-success commit.
Dart clears only batch entrypoint collection between messages, while retaining
its resolver, read cache, builder instances, resources and transmitted dep-graph
identity map. Phase resets and final output/graph commits keep their boundaries.

Optional/lazy dispatch remains serial because its mutable overlay and recursive
demand stack require a different correctness analysis. No opt-in path enters
that scheduler. Post-process requests also keep their existing fixed allocation;
large rewrite/deletion batches were not performance-validated by this fixture.

## Consequences and adoption gate

Two (`tail2`) or three (`tail`/`queue`) protocol batches replace each original batch. Visibility hints
and result envelopes are repeated; moved work may load another worker's
previously untouched dependencies. In-flight work cannot be moved, and a slow
first half can still dominate. Tail stealing preserves a prefix and much of
original membership, but does not preserve the entire original assignment or
per-worker stateful output counters. This is explicitly an experimental mode,
not a compatibility guarantee for arbitrary order-sensitive builders.

Default adoption requires reproducible wall improvement, stock byte equality,
lifecycle/visibility/failure validation and acceptable CPU/RSS/IPC costs across
skewed and balanced workloads, including a representative real application.
Fixture improvements must not be reported as application savings. The
[experiment report](../benchmarks/coarse-batch-2026-10/README.md) records
measurements and the final adoption decision.

## Alternatives

- Fixed count ranges: baseline, no additional IPC and stable worker affinity.
- Fine action RPC/work stealing: deferred because overhead and state movement
  are disproportionate to the measured problem.
- Cost history: deferred; cold behavior, stale costs and storage add complexity
  before any need for persistent estimation is established.
- Extra resolver workers: excluded; it changes the duplicated analysis budget.
