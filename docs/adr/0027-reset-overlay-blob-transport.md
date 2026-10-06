# ADR 0027: Transport phase-reset overlays in one immutable blob

- Status: Accepted
- Date: 2026-10-06
- Replaces the multi-worker per-asset reset spool transport; retains ADR 0002
  transaction boundaries and ADR 0003 worker lifecycle.

## Evidence and decision

Per-asset spool creation/open/close and filesystem metadata operations can
consume hundreds of milliseconds in large phase updates. Use one new file
per reset with a JSON asset-ID to offset/length index. Keep per-asset writes
and ranged worker reads; this is not one write syscall or unconditional
whole-file loading. The [benchmark report](../benchmarks/phase-reset-blob-2026-10/README.md)
shows substantial spool reductions, limited whole-build improvement in the
local fixture, and a reported 2.8% application regen median reduction.

## State and publication boundary

Complete, flush and close the new blob before publishing the existing reset
request to any worker. Retain immutable bytes through every reset response,
including error responses, and remove the blob after the parallel join.
Close and remove partial files on write failure without notifying workers.
Exclusive PID/sequence creation prevents stale-file reuse. Do not reuse blobs
in later resets, builds or watch events. Cleanup is best effort: abrupt exits
or unlink failures can leave ignored files. Legacy spools are ignored.
This ephemeral local IPC does not require durable storage or fsync.

The index covers available overlay values in the union of source/cache
updates. Deletions carry no bytes. Missing values invalidate stale local
values and preserve the existing refresh fallback. One initialized worker
continues to use its in-memory outputs, with an explicit null descriptor;
zero workers require no reset. Workers validate and stage ranged reads before
changing phase state. Invalid descriptors, bounds or incomplete bytes fail
rather than publishing partial phase state. No scheduler, resolver cap,
single-flight default, cache compaction or AOT policy is changed.

Keep phase barriers, same-phase visibility, immutable Analyzer phase state,
read dependency recording, driver reuse and all-success atomic graph/output
commit. No generation-owner omissions or overlap/deferred spool are added.

## Compatibility and validation

Require `reset-overlay-blob-v1` during initialization and require the explicit
`overlay_blob` field in every reset. An old custom/cached worker must fail
initialization rather than silently ignore the new transport. Matched worker
sources are required; regenerated workers advertise the capability.
[Protocol v1](../../protocol/v1.md) specifies the descriptor and lifecycle.

Tests cover source/cache updates, deletion/recreation, multiple and empty
snapshots, malformed ranges and lengths, partial-write cleanup and recovery,
legacy-file isolation, and old-worker rejection. Representative output,
incremental, post-process and watch checks accompany the measurements.
Linux validation does not establish Windows filesystem behavior; there is no
new cross-platform stale-file scavenging policy.
