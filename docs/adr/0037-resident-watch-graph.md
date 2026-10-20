# ADR 0037: Resident committed graph between native watch cycles

- Status: Accepted
- Date: 2026-10-20
- Extends: ADRs 0002, 0005 and 0036

## Decision

Keep the graph returned by a successful native watch build in the watch session.
Return that owned state only after successful output and graph publication, or
an unchanged no-op whose graph save was legitimately skipped. Plan-only and
output verification return no publishable graph. Keep the persisted format,
configuration identity, supported subset and commit order unchanged.

Borrow resident state for event classification, then move it into the next
build as tentative working state. Do not clone a rollback graph. On success,
move the resulting committed graph back into the session. On any preparation,
worker, builder or publication failure, discard the working graph and reload
the persisted state on the next attempt. A partial output commit retains the
existing disk-based recovery contract; resident tentative state cannot mask a
failed graph save.

Keep the existing event-filter gate: no previous graph is supplied until the
session's first successful build. After a later failure, classification still
uses the last persisted graph, reloaded after discarding the tentative state.
Configuration and source transitions keep their existing preflight checks,
including filtered demand, retained-output rejection and topology changes.
Source post-process output classification borrows the newly committed graph
instead of independently decoding the same file.

Check the graph's file length and modification time before event waiting and
again before execution. On Unix, also compare device/inode and change-time
identity. A changed or missing file invalidates residency and uses the existing
validated disk loader, including obsolete/corrupt-state invalidation. If the
filesystem cannot provide modification time, use disk loading. These metadata
checks detect ordinary deletion, replacement and modification, not adversarial
changes preserving all identity fields. State cleanup or direct external graph
editing still requires stopping the watch session, as in the recovery guide.
The native workspace writer lock remains held for the whole session.

## Rationale and consequences

Repeated graph decoding allocates the same strings and maps for event filtering
and execution. Moving ownership avoids both decoding and a full graph clone on
successful cycles. The resident graph adds a live graph between attempts but
removes the separate event-filter copy held across execution. Execution's other
allocations remain unchanged and must still be measured.

Failure recovery deliberately pays a disk reload instead of retaining another
full graph solely for rollback. A cold failure never seeds resident state;
ordinary builder failure remains recoverable and unsupported transitions remain
terminal. Disk publication stays authoritative across restarts. The session
neither writes new persistence metadata nor changes the graph schema.

Use opt-in graph/cycle metrics and wall traces to distinguish disk loading from
resident ownership reuse. Measure latency without those diagnostics, and compare
clean, no-op, one-file and broad changes with the same SDK, worker count, cache,
output bytes and failure recovery. Measurements belong in the PR, not this ADR.
