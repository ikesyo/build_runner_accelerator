# ADR 0046: Bounded input and workspace scheduling

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
applications. Maintain predecessor counts and successor lists; process each edge
on application completion. Index runnable inputs by participation, package and
remaining count, with a separate owner index when workers are pinned. Selecting
a lease does not scan all applications or repeatedly evaluate dependencies.
Prioritize applications without active participants, then package affinity and
remaining input count.

Share an adaptive input queue with ordinary single-package parallel execution.
Start with one-input probes, then target 100ms batches using observed time per
input (excluding initialization/reset), capped at sixteen inputs. This amortizes
worker/IPC latency that can itself approach the former 20ms target. Also cap each
lease at `max(1, floor(unassigned inputs / (2 * eligible workers)))`; expensive
work and the tail use single inputs. Costs are learned within the current application, not across packages or
builders. A sudden cost increase immediately reduces subsequent batches; cheaper
samples rapidly decay warm-up costs. Unexpected expensive inputs within a batch
can still cause stragglers. Preserve request/result order for ordinary execution,
its resolver-worker cap, disabled-store classification and serial fast path.
Use the serial fast path whenever the effective worker count is one, including
a one-input edit with several resident workers, avoiding unnecessary threads
and channels.
Admission stops on an observed failure and all dispatched leases are joined.

Use one deferred pool with at most `--jobs` slots for the whole workspace. Dart
processes start only when a slot receives work, and worker artifact preparation
is shared once. Ordinary and workspace execution share input granularity while
retaining their existing initialization and resolver lifecycles. Without
the shared analysis byte store, an application stays on one process; independent
packages can still run concurrently.

Each process owns one package context at a time. Reassignment initializes it to
dispose the old builder, resource and resolver state. Options, isRoot, phase and
instance identity remain request-local. Rust never changes a running worker's
context. No single-package initialization signature or resolver-use hints are
shared across workspace contexts.

Take a complete phase-visible source/cache overlay and logical-deletion
baseline when an application first receives work. Omit assets already hidden by
the immutable phase guard from transport and baseline equivalence; every batch
still carries that guard. Keep all other logical deletions, including obsolete
outputs absent from the current plan and visible post-process cleanup. Its input leases share the immutable baseline:
its own same-phase outputs are hidden, and predecessor applications are already
complete. A later post-process application checks primary existence against the
latest transaction, including earlier cleanup deletions. Within a phase, reuse an
immutable baseline only when the complete visible overlay and deletion set match. Each
process resets its resolver on a changed baseline; it can retain a resolver for
another application in the same package with the identical baseline. A fresh
package initialization already clears analysis/per-build state, so an empty
baseline needs no additional reset. Phase transitions always create a distinct
baseline, even without new output bytes. Package reassignment still initializes
and disposes the prior package context. Overlay blobs remain alive through every
lease that references them; weak worker references do not prolong blob lifetime.

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
workspace and JSON comparisons for AOT, cleanup and scope transitions. The same
fixture also exercises ordinary single-package dynamic dispatch with 48 inputs,
real overlap, clean/no-op/edit/broad/delete/rename, failure admission, worker exit
rollback and recovery. A separate no-output resolver fixture checks same-phase
baseline reuse across targets, options/isRoot, and resolver dependency edits.

`benchmark_workspace_scheduler.py` compares retained native scheduler binaries
under matched SDK/cache conditions, with stock as an untimed byte reference.
Support JIT and strict AOT worker modes. Complete compilation before timing;
record prepared AOT executable hashes and verify that timed builds do not replace
them. Separate diagnostic observations of builder process executables confirm
the selected mode on Linux.
Record clean/no-op/one-file/broad edits, repeated samples, input-delay profiles,
worker counts and exact output equality. Separate diagnostic histories from timed
runs. Synthetic skew measurements do not establish real-project speedups.

Global phase barriers remain deliberate. Package reassignment and full-baseline
resolver hydration still cost time; locality can compete with load balancing.
The supported workspace subset in ADR 0045 is unchanged. Builder side effects
outside the asset API cannot be rolled back. Larger workspaces and additional
builder configurations require their own comparisons.
