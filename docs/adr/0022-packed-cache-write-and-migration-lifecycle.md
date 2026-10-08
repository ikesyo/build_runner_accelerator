# ADR 0022: Packed cache write and migration lifecycle

The per-key alternatives described below are superseded by
[ADR 0030](0030-compatibility-cleanup-and-disposable-state.md): both caches are
packed-only and PACKED_STORE is removed. Old per-key entries remain untouched.

- Status: Accepted
- Date: 2026-10-02
- Amends: ADR 0021 (duplicate writes and legacy retention)
- Per-record disk synchronization amended by
  [ADR 0025](0025-packed-cache-publication-without-fsync.md).

## Context

Post-merge measurements of PR #73 on a large Flutter workspace found the
analyzer pack growing by about 0.6 MB per warm build. Repeated `.resolved`
records had identical keys and values. Read-time migration also kept the
legacy shards, retaining both copies. Neither changes generated outputs,
but both waste cache space.

## Decision

- Under the exclusive write lock, first adopt sibling appends and repair any
  torn tail. Skip an append only if the indexed value has a valid checksum
  and exactly matches the new bytes. Key equality or checksum equality alone
  is insufficient: changed values and corrupt cached records must be writable.
- A packed put reports success only after flushing the record, or finding an
  identical valid record. Write failures remain best-effort cache misses.
- Keep read-time migration of legacy analyzer entries. After a successful
  packed write, delete that entry's legacy shard file. A checksum-valid
  packed read also deletes its legacy counterpart, including duplicates
  created before this change. A failed write leaves the legacy entry intact.
- Discover legacy filenames once per store instance. Only regular files in
  the analyzer's two-character shard layout are eligible; links, temporary
  files and unrelated paths are ignored. Deletion failures do not fail builds.
- `BUILD_RUNNER_ACCELERATOR_PACKED_STORE=0` continues to use `FileByteStore`
  without migration or cleanup. Concurrent older/opt-out workers may recreate
  shards; a later packed worker discovers and removes them on use.

## Consequences

- Repeated identical writes no longer grow the pack, including writers whose
  initial index predates a sibling write. Value updates still append.
- Successful migration consumes the old entry. Opting out afterwards may
  require recomputation of those entries; outputs remain identical.
- Unread legacy entries and empty shard directories remain. Existing
  duplicate packed records are not compacted, and stale fingerprint directories
  are still not garbage-collected. This change prevents new identical appends.
- No cache format or IPC change is required. Cache deletion affects only warm
  performance; builders and analyzer resolution retain their existing semantics.
