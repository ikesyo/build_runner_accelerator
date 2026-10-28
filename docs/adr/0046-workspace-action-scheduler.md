# ADR 0046: Bounded workspace action scheduling

- Status: Accepted
- Date: 2026-10-28
- Extends: ADRs 0005, 0035 and 0045

## Decision

Schedule ready actions from independent packages within each generated phase of
`build --workspace`. Finish every normal phase before the next, and all normal
builders before post-process builders. Preserve the established order between
related targets, targets in one package, and strongly connected components.

Emit transitive `target_dependencies` and `package_dependencies` on configured
manifest entries, using the official target and package graphs. Reachability
includes targets without selected builders or dirty actions. Package dependencies
also serialize applications of different targets in those packages. These are
additive fields in manifest v11. The frontend regenerates cached manifests
missing them; directly decoded legacy manifests without this evidence remain
serial. SCC ordinals and previous observed reads alone cannot prove independence.

A central controller owns readiness, staged results and the action graph. A
configured application becomes ready when its preceding related applications in
the phase have completed. Its inputs can use multiple workers. Completing the
last input releases successors immediately, without waiting for unrelated
applications. Each free worker receives one input lease; prioritize applications
without active participants, then package affinity and remaining input count.
This avoids fixed input partitions while retaining resident contexts where useful.

Use one deferred pool with at most `--jobs` slots for the whole workspace. Dart
processes start only when a slot receives work, and worker artifact preparation
is shared once. The ordinary single-package parallel path is unchanged. Without
the shared analysis byte store, an application stays on one process; independent
packages can still run concurrently.

Each process owns one package context at a time. Reassignment initializes it to
dispose the old builder, resource and resolver state. Options, isRoot, phase and
instance identity remain request-local. Rust never changes a running worker's
context. No single-package initialization signature or resolver-use hints are
shared across workspace contexts.

Take a complete source/cache overlay and logical-deletion baseline when an
application first receives work. Its input leases share the immutable baseline:
its own same-phase outputs are hidden, and predecessor applications are already
complete. A later post-process application checks primary existence against the
latest transaction, including earlier cleanup deletions. Each process resets its
resolver when entering another application, then reuses it for subsequent input
leases. Overlay blobs remain alive through every lease that references them.

Only the controller records complete, validated action results into the shared
PendingTransaction. Partial application results do not release dependents. On an
observed builder error, worker exit, protocol error or panic, close admission and
join every dispatched worker before returning. Keep each lease's baseline alive
until its worker finishes. Publish outputs and graph only after every phase has
succeeded, using the existing undo-recovery boundary. Introduce no stock fallback.

## Validation and limits

`correctness_workspace_scheduler.sh` compares source and cache bytes with stock
through clean/no-op/edit/broad-edit/delete/rename/failure/recovery. Real builder
rendezvous and process-identified start/end intervals verify jobs=1/2/3,
independent-member and same-package input overlap, dependencies and phase
barriers. A skewed case verifies that C starts after A while unrelated B is still
running. Generated imports/constant resolution, package/target options,
root/non-root contexts, disabled shared storage, metadata migration and worker
exit rollback exercise state isolation and publication. Keep the existing
workspace and JSON comparisons for AOT, cleanup and scope transitions.

`benchmark_workspace_scheduler.py` compares native wave and ready-queue binaries
under matched SDK/cache conditions, with stock as an untimed byte reference.
Record clean/no-op/one-file/broad edits, repeated samples, input-delay profiles,
worker counts and exact output equality. Separate diagnostic histories from timed
runs. Synthetic skew measurements do not establish real-project speedups.

Global phase barriers remain deliberate. Package reassignment and full-baseline
resolver hydration still cost time; locality can compete with load balancing.
The supported workspace subset in ADR 0045 is unchanged. Builder side effects
outside the asset API cannot be rolled back. Larger workspaces and additional
builder configurations require their own comparisons.
