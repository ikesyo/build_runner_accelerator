# ADR 0025: Packed cache publication without per-record fsync

- Status: Accepted
- Date: 2026-10-03
- Amends: ADR 0022 (successful cache write boundary)

## Context

Cold-analysis ownership makes the first worker's cache writes part of every
waiting worker's critical path. `IndexedBlobStore.put` also creates the parent
directory and queries the file length repeatedly for every record, then calls
`flushSync` while holding the append lock. The packed analyzer and directive
caches are disposable, checksum-validated data that can be recomputed. Their
publication to another process does not require durable storage across a
machine crash. The analyzer's ordinary `FileByteStore` similarly writes cache
files without requesting disk synchronization.

Measurements on the cache filesystem show a substantial per-record flush
cost. Filesystem choice must be recorded when evaluating this path.

## Decision

- A successful put means a complete synchronous write has returned, or an
  identical checksum-valid record already exists. Remove per-record
  `flushSync`. The write remains under the exclusive append lock, so another
  writer observes the complete record after ownership changes. Readers still
  stop at an incomplete or invalid tail, and waiting analysis workers refresh
  their index after startup-lock publication.
- Losing cached data after a machine crash is permitted. Missing, partial or
  corrupt entries are misses; the existing scanner and writer-tail repair
  recover them through recomputation. Legacy entries may be removed after the
  synchronous packed write, so a crash can also require recomputing a migrated
  entry. This is an explicit relaxation of ADR 0022's flush-before-success rule.
- Create parent directories only when opening a new write handle. Under the
  append lock, reuse the end offset already obtained during tail adoption and
  repair. Re-seek to that offset after any equality-check read before writing;
  no additional file-length queries are needed.
- Keep the record format, checksum checks, append locks, equality checks and
  best-effort failure behavior. Generated outputs and incremental graph commits
  retain their existing transactional behavior.

## Consequences

The first cold worker publishes its cache sooner and spends less time holding
append locks. Cache durability follows the filesystem's normal writeback,
while cache correctness still follows record validation. The change applies
to both users of `IndexedBlobStore`: analyzer summaries and directive parsing.
It does not introduce a buffered write queue or change the IPC contract.

## Measurements and verification

See the [benchmark note](../benchmarks/cold-worker-analysis-2026-10.md) for
build timings, conditions, output comparisons and verification.
