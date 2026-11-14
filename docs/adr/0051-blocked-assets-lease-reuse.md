# ADR 0051: Reuse batch visibility hints across leases

- Status: Accepted
- Date: 2026-11-14
- Extends: ADRs 0003, 0046 and 0049

## Decision

Keep adaptive input leasing. Large applications can have tens of thousands of
blocked asset IDs, identical across many leases. Repeating their JSON transport
and Dart AssetId parsing makes lease setup dominate builder execution.

Advertise `blocked-assets-reuse-v1`. Each native worker connection retains the
last full batch list and compares the next list by exact content and order. If
identical and the capability is present, send an empty `blocked_assets` list
with `blocked_assets_reuse: true`. Otherwise send the complete list with a false
flag. Workers without the capability always receive complete lists.

Scope the Dart list and parsed immutable AssetId set to the worker runtime,
not module state. Reuse keeps list and set identity; a full list replaces both,
including when empty. Reject reuse without a prior accepted full batch, a
nonempty accompanying list, and nonboolean flags. Decode the whole batch and
parse its assets before replacing runtime state. Nested single builds carry
their own visibility and never replace the batch cache. Both ordinary and lazy
batch clients share the same transport state.

Initialization clears both endpoints' caches. Build and resolver resets retain
them: reuse explicitly names the last batch list, not current resolver state.
Changed visibility, logical deletions or phase contexts still construct and
compare the full candidate list, so a context change cannot silently reuse an
outdated hint. Only one list and parsed set are retained per worker. The Rust
asset RPC remains independently authoritative for visibility.

No graph format, scheduler policy, output publication or build_runner behavior
changes. The capability is an optional transport optimization within the
existing exact-package-version handshake, not cross-release support.

## Evidence and validation

Two supplied private-project reports independently attribute the residual
v0.19.2 gap to repeated batch hints on workspace and single-package builds.
The workspace report measured sent IPC bytes dropping from 523 MB to 63 MB,
and cache-warm clean wall time from 19.3 s to 10.4 s. These are user-reported
results, not measurements of this implementation.

Regression checks cover capability fallback, first/full/repeated/changed/empty
lists, per-connection isolation, malformed reuse, and immutable decoded lists.
Existing stock comparisons exercise phase visibility, nested demand, resets,
watch and workspace reassignment. The scheduler benchmark's
`single-visibility` profile uses 8,192 cheap inputs and two workers to expose
visibility-hint overhead. Separate diagnostics compare IPC bytes alongside
clean, no-op, one-file and broad edits without changing adaptive lease sizing.

Local results and verification limits are recorded in the
[implementation measurement](../benchmarks/blocked-assets-lease-reuse-2026-11.md).
