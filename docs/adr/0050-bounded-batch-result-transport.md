# ADR 0050: Bounded batch-result transport

- Status: Accepted
- Date: 2026-11-14
- Extends: ADRs 0003 and 0049

## Decision

Execution leases remain sized by remaining work and observed action cost.
Output sizes are unknown before execution, so an input-count cap cannot ensure
that a response fits the 256 MiB frame limit without serializing all inputs.

Keep the ordinary single-frame binary reply unchanged. If its encoded metadata
plus raw output bytes exceeds the limit, split only that response into binary
`build_batch_chunk` frames followed by one `build_batch_result`. Both types use
the existing batch metadata shape and batch ID. Preserve original child IDs,
action timings, result order and dependency values. Graph-only fragments are
allowed and dependency keys must be unique across the response.

Only the oversized path partitions metadata and raw-chunk references. Output
bytes are not copied or reconverted for splitting. The normal path still
encodes metadata once and sends one frame. No additional worker initialization,
builder execution, request round trip or scheduler lease is introduced.

The native ordinary and lazy clients collect fragments privately, validate IDs
and the final count, and publish the complete response to their caller only on
the terminal frame. Failed or interrupted streams discard partial results and
dependencies; existing transaction rollback remains authoritative.

An individual action result or dependency entry exceeding the limit fails
explicitly, as before. The frame limit is not raised. This is an internal,
release-coupled protocol extension, not an older-worker compatibility layer.

## Validation

Protocol tests cover the unchanged single-frame layout and allocation, the real
256 MiB boundary with 400 one-MiB outputs, exact-fit results, dependency-only
fragments, result/timing preservation, malformed IDs/counts, duplicate graph
entries and individually oversized results. Production limits are exercised
without retaining hundreds of MiB of test data. The proportional scheduler and
its lease-count regression tests remain unchanged. Ordinary and lazy client
tests replay complete, malformed and interrupted binary responses and verify
that partial dependency edges never escape.
