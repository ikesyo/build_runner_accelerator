# ADR 0052: Batch-level shared request fields

- Status: Accepted
- Date: 2026-11-14
- Extends: ADRs 0003 and 0051

## Decision

Adaptive leases repeat a handful of identical fields in every child request
of a `build_batch`: all requests in a batch already share one phase and
builder kind (a protocol invariant), and in practice they also share the
builder, instance key, root flag, and part-phase index. On wide leases this
repetition is a measurable share of the remaining per-lease encode cost on
the native side and of the JSON decode cost on the worker side.

Advertise `batch-shared-fields-v1`. When the worker advertises it and a
batch of at least two requests is uniform in `builder`, `phase`, `kind`,
`part_phase_index`, `instance_key`, and `is_root`, the native client sends
those fields once in a batch-level `shared` object and omits them from the
child requests. The worker merges `shared` under each child request (fields
present on the child win) and then decodes exactly as before, so the decoded
batch, including the one-phase/one-kind validation, is identical to the
full form. Non-uniform batches and workers without the capability always
receive the full form; single-request batches keep the full form because
there is nothing to deduplicate.

The lifted set excludes per-request data (`id`, `input`, `allowed_outputs`,
`options`, `triggers`, telemetry fields) and the batch visibility hint,
which ADR 0051 already handles. The shared object is stateless: it is sent
in full with every batch that uses it, so there is no cross-batch state to
invalidate on errors, resets, or reconnects, unlike the visibility cache.

No graph format, scheduler policy, output publication or build_runner
behavior changes. The capability is an optional transport optimization
within the existing protocol v1 framing.
