# ADR 0026: Publish byte-store entries through a persistent metadata index

- Status: Accepted
- Date: 2026-10-04
- Replaces the startup scan boundary in ADR 0021; supersedes ADR 0022's migration
  policy for the new format. Retains ADR 0024's publication refresh boundaries
  and ADR 0025's disposable, non-fsynced cache policy.

## Evidence and decision

Packed-store startup reads all historical payloads, validates them and builds
an offset map independently in each worker. With accumulated unused history,
this makes startup time and memory usage depend on values the build never reads.
Measurements show that avoiding unused payloads reduces startup time and memory
usage with accumulated history. Small caches show no general build speedup.
See the [benchmark report](../benchmarks/byte-store-index-2026-10/README.md) for
results, measurement conditions, tradeoffs and reproduction instructions.

Use a separate append-only publication journal containing keys, offsets,
lengths and metadata checksums. Index startup reads metadata, never unused
payloads. A live reader adopts only newly published metadata at explicit
refresh boundaries. Validate each value when it is actually used. Keep exact
byte equality checks when deduplicating puts. This directly removes the measured
startup cost while retaining synchronous publication and best-effort caches.

A checkpoint snapshot or on-disk lookup tree would further reduce startup from
O(historical records), but metadata scanning is a small part of the measured
build time. It does not justify a second checkpoint lifecycle yet.
Compaction would reclaim disk space, but startup no longer touches old values;
there is no measured need for the extra cross-process reclamation protocol.
Batching/mmap do not address the demonstrated unused-payload cost and are not
adopted. Existing record-level value reads remain sufficient for these builds.

## Format and namespace

Packed analyzer caches use `<cache>/byte_store/v2/<fingerprint>/store.v2.bin`
and `store.v2.bin.index`. Directive caches, which use the same store class,
use `<cache>/dep_parse/v3-<sdk>/store.bin` plus its `.index`. Earlier formats
are ignored and rebuilt from empty; there is no migration or compatibility
reader. The explicit per-key opt-out remains separate.

All integers are little-endian. The data pack keeps
`[u32 keyLen][u32 valueLen][key][value][u16 Fletcher16(value)]`.
The journal begins with
`[u32 magic=0x32494253][u64 generation][u32 CRC32(first 12 bytes)]`, then
`[u32 keyLen][u32 valueLen][u64 dataRecordOffset][key][u32 CRC32(header+key)]`.
Keys must be valid UTF-8, 1–4096 bytes, and successive data offsets must be
contiguous. Journal checksums protect offsets, lengths and key identity. A get
also checks the data record's header and exact key before validating the value.
This rejects stale offsets reused for another key after a repair. Value
Fletcher-16 is retained from the existing store/analyzer validator; checksums
are accidental-corruption detection, not an authenticity mechanism.

## Publication and recovery

The data file remains the stable exclusive writer lock. While holding it:

1. Refresh the journal, adopting only complete checksum-valid metadata.
2. Remove an incomplete/invalid journal suffix and unpublished data suffix.
   If data is shorter than its published end, discard the journal and rebuild
   the disposable cache. No full payload reconstruction is required.
3. Compare an existing, validated value before skipping an identical write.
4. Synchronously write the complete data record, then the journal entry.
   Only the completed journal entry publishes the record to other readers.

A failed or killed writer may leave data without publication or a partial
journal entry; readers stop before it and never truncate. A subsequent writer
repairs under the lock. Losing the journal loses cache entries, which are
recomputed. Payload corruption misses for that key without hiding subsequent
valid entries; its replacement is appended. A damaged journal header resets
all entries, and an invalid metadata entry discards its suffix on repair.

Repair writes a new checksummed random 63-bit generation. Refresh checks the
generation even if file length is unchanged: length-only freshness can miss a
repaired journal that regrows to the same size. Startup ownership handoff
refreshes waiting readers; there is no filesystem poll on every new-key miss.
Readiness requires a valid linked value, not just its metadata.

Neither record publication nor generation repair requests fsync. Machine
failure may lose either file or reorder durable writes; bounds, key and checksum
validation cause a miss and recomputation. Cache read/write/close failures stay
best-effort, and an unavailable analyzer cache directory uses MemoryByteStore.
Generated outputs, action graph, overlay, IPC and their existing commit guarantees
are unchanged. Remove caches only with builds stopped; replacing live files by
unlink/rename is not a supported cache-maintenance operation.

## Validation and limitations

Regression coverage includes concurrent writers, exact-byte deduplication,
refresh after publication, incomplete journal retry/repair, unpublished data
repair, corrupt values that do not hide later keys, lost metadata, damaged
generation/header, data loss and equal-size repaired journals. An independent
checksum implementation check guards against matching reader/writer errors.

The metadata index and retained values still grow with unique historical keys;
this does not reclaim disk space or make index memory O(active keys). It avoids
reading and allocating the historical value corpus. Header/key validation adds
work to value reads, and journal publication adds write operations.
