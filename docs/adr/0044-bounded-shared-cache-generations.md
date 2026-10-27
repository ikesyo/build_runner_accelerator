# ADR 0044: Bounded shared cache generations

- Status: Accepted
- Date: 2026-10-27
- Supersedes ADR 0026's single permanent pack ownership and unbounded retention.
  Retains its record format, publication, corruption detection and tail repair,
  and ADR 0025's disposable, non-fsynced cache policy.

## Evidence and decision

Unique content keys and same-key updates both accumulate data and journal
history. Per-worker maps and startup parsing also grow with history; a data-only
budget does not constrain tiny records. With 100,000 successive 1 KiB writes,
bounded generations retained about 40.2 MB of data and 1.12 MB of journal rather
than 104.3 MB and 2.9 MB. Four resident readers used about 83 MB aggregate RSS
(94 MB just before rollover), versus 166 MB with the accumulated history.
These are synthetic map/VM measurements, not complete Analyzer-worker memory.
Measurement commands, build comparisons and validation are recorded in
[the implementation PR](https://github.com/ikesyo/build_runner_accelerator/pull/147).

Use disposable generations, each limited to 256 MiB of data, 8 MiB of journal
and 65,536 historical records. All three budgets count historical updates.
These are fixed internal budgets, not user settings. Defaults leave room for
multiple fixture-sized working sets while bounding metadata startup and maps
independently of payload size. They are per pack, not a total process-memory or
machine-wide quota. Multiple workers each build their own bounded map.

Rejecting all new saves once full is not acceptable. On a full pack, follow the
current generation and retry; if that too is full, publish a replacement with
the requested value and a bounded recent write window. A single entry exceeding
a generation budget is not persisted and must not cause repeated rotations.

Discarding the entire pack creates a hit-rate cliff even when the recent working
set is small. At rollover only, consider the latest 4,096 distinct records
(at most one sixteenth of the record budget), ordered by their latest physical
offset rather than map insertion order. Carry checksum-valid records within one
thirty-second of the data budget (at most 8 MiB) and one eighth of the journal
budget. Reserve room for the requested key/value and journal header first, omit that
key from the seed, and write retained values oldest first, then the request.
All seed records count against the replacement's normal limits. Batch the
validated raw records and their ordinary journal entries under one data-file
lock in the unpublished generation. Data records contain no offsets, so
relocating them preserves their already-validated key/value bytes; new journal
entries bind their new offsets. This avoids repeating checksums, locks and tail
adoption for every copied value. If seeding fails, still attempt the requested
write through normal tail repair. Publish the pointer only after that succeeds.

This uses one index per open store and adds no access tracking, metadata I/O,
locking or maintenance to normal lookups. Selection sorts bounded metadata and
temporarily holds at most 8 MiB of source records plus an 8 MiB batch buffer
and bounded metadata during rollover under control.
There is no timer, in-place compaction or LRU. Old leased packs remain untouched.
Only recent writes are favored; read-only hot entries outside that window can
still be lost and recomputed. Flooding the cache with unused writes can evict
the working set. This reduces a common cliff, not all possible cache misses.

Keeping two half-sized generations was also considered. It retains a larger
recent window, but adds a second index and fallback lookup, and retains more
history at ordinary reopen. Bounded seeding keeps the existing ownership and
read path with a smaller implementation; its extra copy cost occurs at rollover.
Performance comparisons and the retention-window limits belong in the PR's
measurement evidence rather than a general speedup guarantee.

## Ownership, publication and handles

For a logical store path `P`, use `P.generations/`:

- `control`: permanent coordination/lock inode. Never replace or delete it.
- `current`: 32 ASCII hex bytes naming a random generation, plus little-endian
  CRC32 over those bytes. Read and write only under control's exclusive lock.
- `<generation>/data` and `data.index`: ADR 0026's unchanged pack/journal.
- `<generation>/lease-<pid>-<random>`: unique per open store; hold an exclusive
  file lock until all its pack handles have been closed.

Generation creation, pointer reads/publication, lease creation and reclamation
are serialized under control. Its acquisition is nonblocking: contention can
lose a cache operation, never wait indefinitely for maintenance or fail a
build. Normal get uses its leased pack without stat, lock, pointer reads or
maintenance. Normal put uses the existing data-file writer lock; it consults
control only on first open or budget exhaustion. Explicit publication refresh
follows current, as does a new worker/workspace. An unavailable initial open
is latched for get; put and explicit refresh can retry. Explicit refresh adopts
the journal of an already-leased pack even when control is busy and following
the pointer is skipped. The lease protects those handles without holding control.

A process may read and append to a retired generation while leased, up to that
generation's own budget. It follows current on refresh or when its pack fills.
Thus another process's switch never changes which data/journal inode an old
handle references. Old-generation writes may not benefit newer workers, but
remain checksum-validated and bounded. The cache is not a linearizable mutable
key/value database; callers bind values to content identities and use the
existing explicit refresh boundaries.

Each generation has its own stable data-file writer lock. Never truncate,
unlink or rename a leased data/journal pair for rotation. Close data and journal
handles before releasing the lease, including on Windows. Windows mandatory writer locks can temporarily reject concurrent payload
reads; these are cache misses, not corrupt values. Quiet readers reuse their
leased records. Do not add a reader lock to every lookup.

No writer publishes
its new generation until its requested value has been published in the journal,
after any bounded seed. An interrupted seed remains an unpublished orphan.
Failed pointer publication closes the unpublished generation and reports a
miss; subsequent puts retry ownership and publication instead of accepting
local-only writes into an unpublished pack.

Pointer publication needs no rename or fsync: it is small, checksummed, protected
by control, and disposable. A torn/missing pointer loses cache reuse, not output
publication state. Do not import generated-output durability requirements.

## Reclamation and failure handling

Under control, inspect retired generation directories. Skip current and the
local open generation. Probe every foreign lease with a nonblocking exclusive
lock; retain a generation when any lease is live. New lease creation cannot
race these probes because it also holds control. Unlocked crash leftovers can
be reclaimed, including partially created or partially deleted generations.

POSIX record locks belong to processes. Never open/probe a lease whose filename
contains our PID: closing a second descriptor could release another local
store's lock. Track local live lease paths and retain these generations.
Unknown own-PID leases (including PID reuse or a different isolate) and unknown
lock/access errors are retained conservatively and block further allocation;
retry on later rollover. This also prevents unbounded garbage after failed
lease removal or failed directory deletion. Supported workers operate their
cache stores synchronously in one isolate per OS process, as with the existing
pack writer locks; concurrent same-path access from multiple isolates within
one process is not a supported internal worker execution model.

On attach, prune unlocked foreign lease files even in the current generation,
so process exits without explicit close do not accumulate lease files. Refuse
a new lease if that pruning fails or ownership is unknown. If locking a newly
created lease fails, close and best-effort remove that unused lease rather than
leaving an unknown own-PID file that blocks later attempts.

After a successful handoff, reclaim again; opening a current generation also
retries reclamation. No timer or background maintenance is added. With successful
maintenance, retained data is current plus leased retired generations, each with
its own budget. Infinitely many live clients pinning different generations
cannot have a fixed machine-wide bound. Unknown ownership/access failures may
retain additional existing bytes, but do not permit unlimited new allocations.

A kill before pointer publication leaves an orphan; a kill during pointer write
leaves a valid old/new pointer or a cache miss; a kill during deletion leaves an
inactive partial directory to retry. A killed lease owner releases its OS lock.
All cache/maintenance errors are best effort. Full caches continue saving through
rotation under ordinary operation; inaccessible storage, lock contention or
unsafe reclamation may still cause misses and recomputation.

The logical paths remain the same but the generation layout is a separate
namespace. Prior single-pack/per-key files are ignored and retained: an older
executable may still own them, and cannot participate in this lease protocol.
They require offline cleanup with all builds stopped. Release binaries, worker
AOT artifacts and other SDK/fingerprint namespaces are outside this quota.

## Validation limits

Record-level corruption/tail tests remain on IndexedBlobPack. Generation tests
cover repeated updates and distinct keys through many rollovers, byte budgets,
reuse on reopen, same-process and foreign-process live leases, four racing
writers, killed lease owners, torn pointer publication, partial journal/data
writes, interrupted reclamation, bounded recent-record retention, latest-update
ordering, room for full-budget requests and killed unpublished seed writers.
Platform and build benchmark results belong
in the measurement report; Linux tests do not establish Windows/macOS behavior.
