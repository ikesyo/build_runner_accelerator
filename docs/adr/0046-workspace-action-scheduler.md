# ADR 0046: Bounded workspace action scheduling

- Status: Accepted
- Date: 2026-10-28
- Extends: ADRs 0005, 0035 and 0045

## Decision

Run independent packages concurrently within each existing generated phase of
`build --workspace`. Keep all normal phase barriers, and finish normal builders
before post-process builders. Within a phase, preserve the existing execution
order for related targets, targets in one package, and strongly connected
components. A dependency-free wave can contain at most `--jobs` applications.
Only applications with dirty actions participate; dependency reachability still
includes paths through targets with no selected builders or dirty actions.

Emit transitive `target_dependencies` and `package_dependencies` on configured
manifest entries, using the same official target and package graphs as phase
ordering. Package dependencies serialize even applications of different targets
in those packages. This is additive optimization
metadata in manifest v11: absent metadata serializes execution. The frontend
regenerates on-disk manifests missing these fields, so upgrading does not leave
existing workspaces permanently serial. SCC ordinals
alone are insufficient to establish independence. Do not infer independence
from previous action reads or assume an unobserved read cannot occur.

Use one worker pool for the whole workspace, with at most `--jobs` resident
processes. Admit one worker per independent application before allocating spare
workers across its inputs. Use balanced contiguous input ranges and merge results
in stable application/input order. The ordinary single-package parallel path is
unchanged. Without the shared analysis byte store, a workspace application uses
one process, while independent packages can still run concurrently.

Track the initialized package separately for each process. Prefer matching
resident contexts; on reassignment, initialize that process to dispose its old
builder, resource and resolver state. Pass options, isRoot, phase and instance
identity from each immutable configured action. Never change the package of a
process while it owns a running batch. The pool's single-package initialization
signature and resolver-use hints are not shared across workspace contexts.

Before every lease, hydrate the resolver with the complete current source/cache
overlay and logical deletions, even for newly started or reassigned processes.
Use the existing reset-overlay blob protocol and keep the blob alive until all
threads join. The action visibility model continues to hide same/later-phase
outputs. No peer sees a partial result from its wave.

Join every dispatched worker on success, worker error or panic. Record results
only after joining the wave; abort on any failed result or validation error.
All waves share one PendingTransaction and the existing all-success publication
and undo-recovery boundary. No intermediate output or graph is published, and no
stock fallback is introduced.

## Validation and limits

`correctness_workspace_scheduler.sh` compares source and cache bytes with stock
through clean/no-op/edit/broad-edit/delete/rename/failure/recovery. A real Dart
builder rendezvous plus process-identified start/end intervals proves independent
member overlap. Interval sweeps check jobs=1/2/3, same-package input overlap,
dependency ordering and phase barriers. The generated-library resolver consumer,
cross-package generated-asset read, distinct options, root/non-root options and
whole-workspace failure snapshots exercise state isolation and publication.
Keep `correctness_workspace.sh` and `correctness_workspace_json.sh` as separate
compatibility checks, including AOT, post-process cleanup and scope transitions.

Scheduling uses waves, not work stealing: a slow batch can hold the next wave.
Full-baseline resolver hydration favors correctness over minimal reset traffic.
Builder execution must follow the asset API and declared target graph; arbitrary
external side effects cannot be rolled back. The supported workspace subset in
ADR 0045 is unchanged. Concurrency evidence is not a speedup measurement; any
performance claim still requires the comparisons in ADR 0005.
