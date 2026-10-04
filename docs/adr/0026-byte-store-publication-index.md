# ADR 0026: Publish byte-store entries through a persistent metadata index

- Status: Accepted
- Date: 2026-10-04
- Replaces the startup scan boundary in ADR 0021; supersedes ADR 0022's migration
  policy for the new format. Retains ADR 0024's publication refresh boundaries
  and ADR 0025's disposable, non-fsynced cache policy.

## Evidence and decision

PR #80 already removed per-record fsync and redundant filesystem operations.
This branch was derived from its original head
`b7db40a0547f78f97f2dfede4a39e0401697bf7f`, then rebased onto main after
PR #80 merged. The final comparison baseline is merged main
`5dc2e1bf166fa4b4f6ba4a41f030d66822216ea6`, including its fingerprint fix and
single-flight disabled by default. The remaining packed-store startup reads all
historical payloads, validates them and builds an offset map independently in each worker.

An initial AOT probe measured a 500 MiB pack's index startup at 904 ms and
514 MiB peak RSS; reading all values alone took 193 ms and a standalone
Fletcher-16 workload over the same byte count took 353 ms. An 8 MiB pack's
startup took 11 ms. Repeated, alternating probes below confirm that payload
scanning is material once unused history accumulates. Normal fixtures' packs
are much smaller, so their warm startup has little room for improvement.

Use a separate append-only publication journal containing keys, offsets,
lengths and metadata checksums. Index startup reads metadata, never unused
payloads. A live reader adopts only newly published metadata at explicit
refresh boundaries. Validate each value when it is actually used. Keep exact
byte equality checks when deduplicating puts. This directly removes the measured
startup cost while retaining synchronous publication and best-effort caches.

A checkpoint snapshot or on-disk lookup tree would further reduce startup from
O(historical records), but the measured 32,000-entry journal is only 1.1 MiB and
loads in about 19 ms. It does not justify a second checkpoint lifecycle yet.
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
repaired journal that regrows to the same size. PR #80's startup ownership
handoff still refreshes waiting readers; there is no filesystem poll on every
new-key miss. Readiness requires a valid linked value, not just its metadata.

Neither record publication nor generation repair requests fsync. Machine
failure may lose either file or reorder durable writes; bounds, key and checksum
validation cause a miss and recomputation. Cache read/write/close failures stay
best-effort, and an unavailable analyzer cache directory uses MemoryByteStore.
Generated outputs, action graph, overlay, IPC and their existing commit guarantees
are unchanged. Remove caches only with builds stopped; replacing live files by
unlink/rename is not a supported cache-maintenance operation.

## Measurements

Linux x64, Dart 3.13.3, Rust 1.98.1 release frontend, two-CPU cgroup quota,
`--jobs 4`. Both workers compile against the same fixture package configuration
and dependency lock. Every paired build uses the same absolute fixture directory
and actual cache root `/workspace/byte-store-results/build-cache`, on the
workspace overlay filesystem, never `/tmp`. Each row is a median of five
alternating runs; no correctness/verification jobs ran during measurement.
The OS page cache is not flushed; copying cache templates can warm it.

The benchmark invokes the release frontend directly with an explicit compiled
worker (`BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH`). AOT compilation, AOT artifact
validation, launcher startup and release download are excluded. The SDK summary
is warm. Empty clean removes both analyzer and directive caches; warm cases
restore independently primed equivalent caches for each format. Clean removes
outputs and graph; no-op follows clean. One-file renames a model field from
`value` to `valueEdited`; broad renames it to `valueBroad` in all inputs,
including the previously edited file, so every input and its output change.
The source files are restored afterwards. Both timed lanes use main's default
parallel analysis (single-flight disabled); metrics are disabled.

### Isolated AOT probes

Small: 2,000 entries × 4 KiB (8 MiB). Large: 32,000 entries × 16 KiB (500 MiB).
Writes add 2,000 new entries to an independently restored pack. Probe files
live beside the build cache under `/workspace/byte-store-results`, on the same
workspace filesystem; the build measurements use the production cache paths.
CPU uses Linux
CLOCK_PROCESS_CPUTIME_ID, including Dart mutator/GC threads. Peak RSS is for the
whole isolated process, including untimed index preparation for get/write.
The initial OS thread's schedstat is unsuitable because the mutator runs on
another thread; it was replaced with the process clock before final reporting.

| Cache / operation | Before wall / CPU ms | After wall / CPU ms | Before / after peak RSS MiB |
| --- | ---: | ---: | ---: |
| Small index startup, including validation | 16.30 / 16.48 | 1.23 / 1.41 | 13.8 / 9.4 |
| Small bulk file read / allocation | 3.12 / 3.26 | 0.05 / 0.18 | 13.1 / 9.4 |
| Small UTF-8 / offset map only | 0.56 / 0.70 | 0.54 / 0.70 | 13.7 / 9.4 |
| Small raw value reads | 9.61 / 10.16 | 9.12 / 9.46 | 9.4 / 9.4 |
| Small value checksum workload | 5.28 / 5.48 | 5.44 / 5.57 | 9.4 / 9.4 |
| Small validated gets | 15.56 / 15.89 | 20.13 / 20.29 | 18.5 / 15.1 |
| Small writes | 29.41 / 29.92 | 41.19 / 41.59 | 22.5 / 14.7 |
| Large index startup, including validation | 723.55 / 724.51 | 19.38 / 20.74 | 514.4 / 17.9 |
| Large bulk file read / allocation | 177.10 / 178.52 | 0.62 / 0.79 | 506.2 / 9.6 |
| Large UTF-8 / offset map only | 12.72 / 13.33 | 9.31 / 9.91 | 512.7 / 13.1 |
| Large raw value reads | 167.25 / 169.63 | 157.26 / 158.47 | 9.4 / 9.4 |
| Large value checksum workload | 338.03 / 338.29 | 344.62 / 344.47 | 9.4 / 9.4 |
| Large validated gets | 562.25 / 567.03 | 563.10 / 567.16 | 547.0 / 34.9 |
| Large writes | 75.43 / 77.12 | 98.96 / 97.39 | 544.1 / 44.8 |

Raw read/checksum probes isolate component workloads and must not be summed
as an exact decomposition: bulk startup I/O, individual gets and synthetic
checksum loops have different allocation/syscall patterns. The extra key/header
checks slow small-value gets; large-value gets are
approximately unchanged after reducing temporary views to one record read and
one header view. Journal publication adds write/lock-refresh operations. This
change targets startup and memory with unused history; it does not claim faster
hot reads or writes. Metadata-only map construction is inexpensive relative to
historical payload allocation and checksum work. The candidate still validates
metadata CRCs during startup, and requested values during gets.

### Actual JSON builds

The normal ten-input analyzer pack is 102,608 bytes; the 500-input pack is about
880 KiB (901,263 bytes baseline). The accumulated case adds 32,000
valid unused linked entries, totaling 500 MiB of historical values, in that
fixture's actual analyzer pack, not a separate unused fingerprint. This is
synthetic history around real builders, not the unavailable reference workspace.
The candidate's large journal is 1.1–1.2 MB.

| Inputs / cache | Case | Before s | After s |
| --- | --- | ---: | ---: |
| 10 / empty | clean | 0.1412 | 0.1430 |
| 10 / normal warm | clean | 0.1260 | 0.1355 |
| 10 / normal warm | no-op | 0.0036 | 0.0037 |
| 10 / normal warm | one-file | 0.0845 | 0.0863 |
| 10 / normal warm | broad | 0.1363 | 0.1405 |
| 10 / accumulated | clean | 0.8046 | 0.1486 |
| 10 / accumulated | no-op | 0.0036 | 0.0036 |
| 10 / accumulated | one-file | 0.7194 | 0.1032 |
| 10 / accumulated | broad | 0.8177 | 0.1578 |
| 500 / empty | clean | 1.1041 | 1.0784 |
| 500 / normal warm | clean | 0.9623 | 0.9193 |
| 500 / normal warm | no-op | 0.0419 | 0.0410 |
| 500 / normal warm | one-file | 0.1462 | 0.1448 |
| 500 / normal warm | broad | 1.1669 | 1.1991 |
| 500 / accumulated | clean | 1.6401 | 1.0329 |
| 500 / accumulated | no-op | 0.0414 | 0.0419 |
| 500 / accumulated | one-file | 0.7838 | 0.1672 |
| 500 / accumulated | broad | 1.8501 | 1.2113 |

Normal-cache differences have overlapping samples: ten-input broad ranges are
0.128–0.144s before and 0.127–0.147s after; 500-input warm clean ranges are
0.869–1.012s before and 0.907–0.971s after. There is no demonstrated general
speedup on small caches. No-op starts no workers and does not read the store.

Accumulated ten-input clean/broad child CPU falls from 1.50/1.54s to
0.25/0.27s, and peak process RSS from 544/547 MiB to 48/50 MiB. Accumulated
500-input clean/broad CPU falls from 3.00/3.36s to 1.84/2.15s; peak
process RSS falls from 585/587 MiB to 91/91 MiB. Linux wait4 reports
CPU including reaped worker children; max RSS is the largest process, not the
sum of simultaneous workers. CPU figures are medians of each run's user+system
time. The approximately 91-second reference workspace is unavailable, so no
speedup is asserted for it.

Separate metrics-enabled 500-input warm-clean profiles confirm the boundary:
aggregate byte-store get time is 16.5→14.9ms for normal caches and
1,309→58.3ms with accumulated history. Put time is 0.70→1.30ms and
0.87→6.69ms respectively. Driver creation stays about 37–40ms per first
resolver; these probes observed two first-resolver workers with `--jobs 4`.
These diagnostic runs are excluded from the timing table; metrics get time
includes lazy initial index construction, so isolated probes above separate
that cost. Full component counters are in
[build-profiles.json](../benchmarks/byte-store-index-2026-10/build-profiles.json).

All 180 measured builds match their case's generated source and native cache
output bytes across formats (SHA-256 comparisons). Separately, both fixtures'
clean/no-op/one-file/broad source outputs match stock build_runner. With the
shared cache root blocked by a regular file, both candidate builds succeed and
produce those same clean outputs.

## Reproduction and artifacts

Use `tool/benchmark_blob_store.dart` as an isolated Linux AOT probe: compile it
against the baseline/candidate store source, then run `seed`, `index`, `read`,
`checksum`, `get`, `write` in fresh processes with the real cache path, record
count and value size. `load` isolates bulk file read/allocation; `index-only`
preloads bytes and isolates UTF-8 decoding/map construction without checksums.

Prepare a baseline worker from main `5dc2e1b` and a candidate worker against the
same absolute fixture package configuration. Keep SDK `lib`/`version` beside the
benchmark worker `bin` as in the production AOT SDK facade. Run:

```sh
python3 scripts/benchmark_shared_byte_store.py \
  --baseline-worker /workspace/byte-store-results/baseline-worker \
  --candidate-worker /workspace/byte-store-results/candidate-worker \
  --baseline-probe /workspace/byte-store-results/baseline-probe \
  --candidate-probe /workspace/byte-store-results/candidate-probe \
  --cache /workspace/byte-store-results/build-cache \
  --results /workspace/byte-store-results/comparison-final \
  --dart "$PWD/.toolchains/dart/dart-sdk/bin/dart" \
  --frontend "$PWD/rust/target/release/build_runner_accelerator" \
  --jobs 4 --repeats 5 --counts 10 500
```

The supplied cache is disposable: the script clears it and restores its own
format-specific templates. Retained per-run timing/resource rows are in
[builds.csv](../benchmarks/byte-store-index-2026-10/builds.csv) and
[micro.csv](../benchmarks/byte-store-index-2026-10/micro.csv). Build rows also retain
a digest of the sorted output-file SHA-256 manifest for each case. Full commands,
logs, output digests, workers and templates remain under
`/workspace/byte-store-results`; they are local artifacts, not distributed SDK
binaries. The checked-in harness and probes make the comparison repeatable.

## Validation and remaining limits

The full repository verification matrix passed on the PR #80-based implementation
before the main rebase:

- `VERIFY_LEVEL=full bash scripts/verify.sh` (all five suites)
- `bash scripts/watch_smoke.sh`
- `bash scripts/correctness_freezed.sh`, `watch_smoke_freezed.sh`, `benchmark_freezed.sh`
- `bash scripts/correctness_riverpod.sh`, `watch_smoke_riverpod.sh`, `benchmark_riverpod.sh`
- `bash scripts/benchmark_matrix.sh`

After rebasing onto main `5dc2e1b`, formatting, analysis, all 140 Dart tests and
97 Rust tests passed. The two required `scripts/verify.sh` invocations (default
and `VERIFY_ARBITRARY_BUILDER=1`) both passed on the rebased tree. The final 180-build comparison, eight stock-output
comparisons, and two blocked-cache builds above all use the rebased code.
The full matrix was not rerun after the rebase. An independent Python zlib
CRC32/layout check validates all 66,086 metadata records in the final cache
templates, preventing a matching reader/writer checksum bug from escaping tests.

Focused regression coverage includes concurrent writers, exact-byte
deduplication, refresh after publication, incomplete journal retry/repair,
unpublished data repair, corrupt values that do not hide later keys, lost
metadata, damaged generation/header, data loss and equal-size repaired journals.

The metadata index and retained values still grow with unique historical keys;
this does not reclaim disk space or make index memory O(active keys). It avoids
reading and allocating the historical value corpus. Small-value workloads can
pay the validated-get cost shown above, and writes pay for the second publication
file. Networked filesystems and cross-platform durability behavior were not benchmarked here;
the implementation retains the existing synchronous file-lock approach.
