# Graph, hash and JSON CPU-extension investigation

This follow-up measures the B/C/D candidates left untested in PR #163. Its
previous deferrals are not treated as negative performance evidence. Before rebasing, the selected
changes reduced median No-op time by 6.9% and One-file time by 6.6% in the final
500-feature workload comparison. **Clean and Broad do not establish a consistent
improvement; this is not a universal build-speed claim.**

## Rebase onto merged PR #163

On 2026-11-06 this branch was rebased onto main `5ae9ee8`, which includes
PR #163. Both the cached Finder and empty-change early return are retained.
The snapshot merge drains both iterator tails before checking for an empty
change set, so additions/removals at either tail still propagate correctly.
The performance tables below are historical measurements from pre-rebase
commit `bd18bee` against `617bb0b`; they are **not** measurements of additional
benefit over merged PR #163. No E2E benchmark was repeated for this rebase. Rust tests after integration
passed (233 tests, three ignored), as did Clippy and formatting checks.

## Baseline and scope

Baseline: main `617bb0bf6fba9193527d557c39a7c40ce3730aae`, fetched on
2026-11-04. PR #163 was still an open, unmerged Draft at head
`4f9c73db92979508e42384d77ca98ad222e457cd`. Its cached part Finder and empty
reverse-closure shortcut were **not** included in the measured proposal. Neither
was reimplemented; both now come from main after rebasing.
Main already prunes the FVM SDK from asset discovery, batches resolver work,
reuses output digests, validates eligible AOT file digests through local stamps,
and caches Dart directive dependencies. Those optimizations remain in place.

The selected production changes are:

- Merge the two sorted snapshots in `GraphState::dirty_context`, replacing two
  tree lookups per asset with ordered iterators. Existence and digest determine
  changes; size alone still does not. Reverse propagation is unchanged.
- Use algorithm-tagged BLAKE3-256 for Rust's internal disposable-state digests.
  Keep the separate Dart/Rust worker-source identity contract unchanged.

No custom production intrinsics, global native CPU flags, scheduler changes,
JSON parser changes, or binary protocol changes are introduced.

## Conditions and measurement method

All new timings use one Linux x86_64 KVM host, Xeon Platinum 8573C, three visible
CPUs, two-CPU cgroup quota (`200000 100000`), 8 GiB memory limit. Stable
Rust/Cargo 1.98.1 and Dart 3.13.3. No results from PR #163's separate environment
are used as controls even though its reported CPU model matches.

Normal Release, evaluation-only `-C target-cpu=native`, and the proposed
portable Release are separate binaries. All compilation finishes before timed
runs. Diagnostic instrumentation is used separately and is disabled for E2E.
E2E includes the Dart launcher, two workers, the same lockfile/resolution and
an explicit prewarmed AOT worker for warm cases.

The mixed application contains 500 feature modules, 1,001 source inputs and
1,001 generated public files: Freezed 4.0.1, Riverpod generator 4.0.9,
json_serializable 6.14.1 and build_runner 2.16.2. The recorded resolver graph
has 1,787 nodes and 3,706 edges; its snapshot has 3,797 entries, about 13 MB of
recorded content. Most edges are sparse. This is one workload, not a density
model for all applications.

Kernels use seven time batches per row. A separate untimed call counts Rust
allocator allocation requests and maximum live requested bytes. Input storage
and persistent indexes are excluded from a reuse row; construction rows include
index construction/destruction. These figures are not RSS, allocator reserved
memory, or hardware cache-miss counts. Timers/black_box impose a floor on very
short kernels. Compare large effects, not nanosecond differences near that floor.
All closures destroy their owned allocations before returning. JSON figures
exclude the prebuilt reference DOM; they measure a fresh parse and its result.
E2E RSS is the measurement helper's maximum child-process RSS, not simultaneous
aggregate memory of the launcher/frontend/workers.

Initial, one-sample Release controls were Clean 42.067 s, No-op 0.305 s,
One-file 0.577 s and Broad 9.147 s. Clean includes worker AOT compilation and
uses an independent empty shared cache. Initial observations are not compared
directly against later warm candidates to claim a speedup.

## B: graph and set processing

Current storage is a String-keyed ordered adjacency map. Dirty checks compute
changed asset IDs once, build reverse adjacency, then use a HashSet visited set
and a stack. The closure is shared by actions; it is not recomputed per action.
Standard HashSet/HashMap probing already uses SwissTable group operations.

The standalone evaluation compares:

1. borrowed String-keyed BTreeMap and HashMap reverse adjacency;
2. integer IDs with a HashMap interner and Vec adjacency;
3. dense u64 visited bits, sparse integer HashSet, and RoaringBitmap;
4. full ID/index construction plus traversal, versus an already-built index.

All representations are checked against the original closure result. Inputs
include 64/4,096/32,768 nodes, degree 2/32, duplicate edges, a shared dependency,
local chains, one changed seed and 10% seeds. Real-graph seed cases use the
lexicographically first/last IDs and every tenth key; the name `leaf` in raw
kernel output is only a seed convention and does not assert that a real node
has no dependents. Conversion includes IDs for dependency-only vertices.

Representative real-graph Release results (microseconds; peak requested heap):

| Seed / representation | Time us | Allocations | Peak bytes |
| --- | ---: | ---: | ---: |
| last / String BTree | 524.6 | 1,588 | 258,776 |
| last / String HashMap | 326.5 | 1,391 | 245,584 |
| last / dense bits, rebuild | 618.5 | 1,402 | 219,400 |
| last / dense bits, reuse | 5.1 | 16 | 33,040 |
| last / sparse IDs, rebuild | 682.6 | 1,410 | 228,408 |
| last / sparse IDs, reuse | 30.3 | 24 | 42,048 |
| last / Roaring, rebuild | 654.9 | 1,411 | 221,384 |
| last / Roaring, reuse | 27.0 | 25 | 35,024 |
| 10% / String BTree | 602.4 | 1,585 | 265,208 |
| 10% / String HashMap | 392.5 | 1,388 | 252,016 |
| 10% / dense bits, rebuild | 649.7 | 1,405 | 222,232 |
| 10% / dense bits, reuse | 15.6 | 19 | 35,872 |
| index only | 628.5 | 1,386 | 186,424 |

The dense visited set itself is compact, but its ID map/adjacency conversion is
more expensive than one existing closure on this graph. Reuse can amortize
that cost; a one-shot rebuild cannot. Retaining it across mutations would need
an explicit lifetime/invalidation design and retained-memory budget. No all-pairs
bit matrix is justified. The index has not been integrated into resident watch.

HashMap reverse adjacency wins on this real graph and on the largest dense
synthetic inputs, but the 64-node degree-2 single-seed case regresses from
6.06 to 7.92 us. It is not adopted without a graph-size/reuse policy validated
on more workloads. No heuristic threshold is introduced from this one corpus.

POPCNT does not accelerate membership tests by itself. Dense visited membership
uses shifts/masks; word unions could help repeated multi-source set operations,
but these builds need one reverse closure. TZCNT/bit scans already occur in
hash-table probing; native code additionally contains POPCNT/LZCNT. The selected
merge avoids searches rather than depending on those optional instructions.
Hardware cache counters were unavailable; cache-efficiency conclusions are
limited to layout, allocation and elapsed-time evidence. Separate set kernels
measure duplicate insertion, intersection/union cardinality and filtering. At
32,768 IDs and 1% left-set density, String sets take 1,014.5 us / 574,496 peak
bytes; bitsets with reused IDs take 644.6 us / 8,192 bytes, while rebuilding the
ID map takes 1,462.0 us / 1,646,608 bytes. Native versions take 1,008.8 / 622.3 /
1,439.1 us respectively. The 64-ID, 1% case likewise regresses when converting
(1.91 us String versus 2.25 us bitset rebuild). The experiment includes both
sets being built; it is not an isolated word-AND throughput claim.

The exact production dirty_context bodies are also compiled independently
against identical snapshots. Two passes reverse variant order. This includes
change detection, reverse adjacency, traversal and destruction. The merge adds
no allocation and keeps the same peak heap; its exhaustive reference test covers
6,561 snapshot pairs, additions/removals, missing entries, content changes,
size-only changes, duplicate edges and dependency cycles.

Median of the two seven-batch pass medians, microseconds:

| Nodes / case | Main | Native main | Merge | Allocations / peak bytes (all three) |
| --- | ---: | ---: | ---: | --- |
| 64 / no-op | 10.30 | 10.06 | 7.20 | 78 / 9,712 |
| 4,096 / no-op | 2,231.35 | 2,197.34 | 1,423.11 | 4,787 / 647,368 |
| 32,768 / no-op | 20,850.14 | 20,632.43 | 13,545.03 | 38,241 / 5,185,920 |
| 32,768 / one leaf | 19,462.59 | 20,158.68 | 11,769.32 | 38,244 / 5,186,152 |
| 32,768 / shared dependency | 27,470.44 | 27,744.36 | 19,783.85 | 38,259 / 7,381,492 |
| 32,768 / disjoint snapshots | 44,943.84 | 45,257.51 | 39,606.93 | 38,274 / 11,805,104 |

The real app has far fewer resolver vertices than the largest synthetic case.
These kernel percentages are not extrapolated to E2E percentages. In particular,
the existing output verification hashes remain a large part of `dirty_check`.

## C: hash inventory and correctness

| Use | Current before this change | Treatment |
| --- | --- | --- |
| Source/dependency/output snapshots; output reuse; watch expected bytes | Rust FNV-1a-64 | BLAKE3-256 with `b3-` tag |
| Configuration, package/compiler/manifest/AOT cache identities | Rust FNV-1a-64 | Same tagged BLAKE3; changed identities select new cache entries |
| Publication undo backup content verification | Rust FNV-1a-64, journal v1 | BLAKE3, journal v2; old evidence is rejected before writes and preserved |
| Worker-source producer/consumer identity | Dart FNV-1a-64 and Rust comparison | Unchanged dedicated function; not a security authenticator or a legacy reader |
| Dart asset-read digest, resolver reads, directive cache, byte-store fingerprint, factory probe | SHA-256 plus existing reuse | Unchanged |
| Release archive/binary integrity, signed release metadata | SHA-256/signature verification | Unchanged; never substitute noncryptographic hashes |

A separately instrumented baseline No-op called the Rust internal digest 8,810
times over 31,281,446 bytes. Median input was 1,991 B, p90 11,959 B, maximum
76,923 B; minimum zero. Hash computation plus hex formatting measured about
41.3 ms. Initial scan reads were 2,004 calls / 9,256,242 bytes /
52.0 ms; this excludes other output/dependency/config reads. It is not a claim
that all filesystem time is in those calls. Instrumented enclosing stages were
initial snapshot 133.0 ms, planning 23.7 ms and dirty checking 27.1 ms. Dirty
checking includes output evidence hashing, not just dirty_context.

These are attribution diagnostics, not E2E latency measurements: timers and
logging perturb execution. Warm No-op starts no worker, so its IPC JSON count
is zero. Existing scoped AOT receipts avoid rehashing eligible settled files;
output evidence collection already deduplicates physical reads. The measured
remaining work is not attributed to those avoided calls.

The first diagnostic used stationary post-Broad inputs; the following table
uses restored base inputs, explaining the small byte-count difference. A second
diagnostic attributes the remaining No-op calls as follows. Timings are
summed elapsed hash/format intervals, not instrument-free process CPU time.

| Call site / purpose | Calls | Input bytes | Hash/format ms |
| --- | ---: | ---: | ---: |
| snapshot scan | 2,004 | 9,241,234 | 12.01 |
| recorded generated assets | 2,003 | 10,101,726 | 12.85 |
| tracked dependency assets | 286 | 1,648,111 | 1.97 |
| deduplicated output-path checks | 2,003 | 10,101,726 | 15.33 |
| planning placeholders | 2,004 | 18,036 | 0.12 |
| empty glob memberships | 501 | 0 | 0.05 |
| configuration/workspace/worker identities and virtual markers | 9 | 95,605 | 0.16 |

Existing output-read deduplication is within the output-evidence collector; it
does not remove all reads across the scan/generated/output-check stages. Reusing
more across those stages would need to preserve source/cache path distinctions
and publication checks; it is not assumed safe from a matching logical ID alone.
The Broad diagnostic also hashes publication undo backups (1,001 calls / about
7.77 MB, attributed through a function-pointer adapter). Backup byte verification
is not removed to reduce hash work.

Alternatives are xxHash3-128, BLAKE3-256, and CRC32C. The evaluation includes
16/128/4,096/65,536 B and 4 MiB inputs, real files, hex formatting, 8 KiB
streaming chunks, and two-thread large-buffer runs. Buffered file reading is
measured separately; no production streaming or thread policy is changed.

CRC32C is only 32 bits, linear and intentionally forgeable; it is unsuitable as
the sole build-reuse identity. xxHash3-128 is attractive for benign identities
but is noncryptographic. Full BLAKE3-256 gives a stronger collision boundary
than the previous 64-bit FNV while substantially reducing large-input cost.
For n independent values, birthday collision probability is approximately
n(n-1)/2^257. Generic adversarial collision resistance is about 2^128; preimage
resistance is about 2^256. This is not a proof of zero collisions or cache
authentication. Local receipts retain their existing trusted-filesystem/stamp
assumptions; an attacker who can replace all cache metadata is outside that
reuse model. Release authentication remains a separate boundary.

Migration has no old-format reader: graph schema 8 discards schema-7 evidence;
`b3-` identities select new internal cache namespaces; the validation receipt is
`aot-validation-digests-b3.json`; journal v2 refuses v1 before any recovery write.
Old disposable cache entries may remain on disk but cannot authorize current
reuse. Existing interrupted v1 transactions must be recovered using the matching
frontend before upgrading. Undo evidence must not be deleted as cache cleanup.
The Rust/Dart worker-source FNV contract stays separate and is exercised with
matching empty/ASCII/Unicode vectors.

Hash-return-string kernels, microseconds. FNV includes its 16-character hex
result, xxHash its 32-character hex, and BLAKE3 the actual production 67-character
`b3-` + hex result. Native columns are evaluation-only builds of the same algorithm.

| Input | FNV | Native FNV | xxHash3-128 | BLAKE3 | Native BLAKE3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 16 B | 0.083 | 0.083 | 0.093 | 0.136 | 0.184 |
| 128 B | 0.230 | 0.227 | 0.094 | 0.203 | 0.242 |
| 4 KiB | 5.153 | 5.468 | 0.275 | 1.288 | 1.206 |
| 64 KiB | 88.669 | 82.526 | 3.094 | 10.833 | 10.218 |
| 4 MiB | 5,546.025 | 5,220.638 | 216.299 | 720.246 | 723.452 |

The final BLAKE3 result needs one 67-byte allocation. Short 16-byte keys regress;
128-byte keys are close and compiler-layout sensitive. This is an explicit cost,
not hidden by the larger-file results. The remaining workload contains enough
larger content for the steady E2E result to improve.

Real 1,989-byte model / 11,959-byte generated model, ordinary Release:

| Input | FNV + hex us | xxHash + hex us | BLAKE3 + tag us | Buffered read only us |
| --- | ---: | ---: | ---: | ---: |
| model source | 2.618 | 0.187 | 1.952 | 1.484 |
| generated model | 15.692 | 0.616 | 4.723 | 2.094 |

Raw 4 MiB CRC32C is 182.4 us, but is not a valid standalone reuse identity.
For already-buffered input, 8 KiB updates cost about 1.11 ms for BLAKE3 versus
0.73 ms in its one-shot raw hash; xxHash and CRC also have streaming rows.
The two-thread test hashes two independent 2 MiB messages (4 MiB total), with
thread creation/join included. It is a throughput test, **not** a parallel hash
of the same single file or an attempted digest-combining algorithm. Ordinary
Release results were approximately 2.96 ms FNV, 0.35 ms xxHash, 0.78 ms BLAKE3,
and 0.26 ms CRC: startup overhead matters for the already-fast hashes. No hash
thread-pool or Rayon policy is added.

Actual warm-page-cache file-read kernels also compare `fs::read` + hash with
8/64 KiB reads. Every streaming result is checked against the complete-file
result for FNV, xxHash3-128, CRC32C and BLAKE3 before timing:

| 4 MiB file / algorithm | Full read + hash us | 8 KiB stream us | 64 KiB stream us |
| --- | ---: | ---: | ---: |
| FNV | 5,765.9 | 5,624.4 | 5,446.3 |
| BLAKE3 | 1,247.7 | 1,485.6 | 1,072.7 |
| Native BLAKE3 | 1,244.9 | 1,432.1 | 1,081.5 |

Full-read BLAKE3 peak requested heap is 4,194,371 B (two allocations); streaming
uses 8,192 / 65,536 B peak (three allocations, including an avoidable formatting
reallocation in this unadopted prototype). The buffer is allocated once per file
and reused for its reads. For the real 1,989-byte source, full read is 3.51 us /
2,056 B peak, while 64 KiB streaming is 4.60 us / 65,536 B. A large-file policy
could be useful, but a blanket switch is not justified for this input distribution
(maximum measured No-op hash input about 77 KB). Cold storage, memory pressure
and cross-file buffer pooling remain untested. Production file I/O is unchanged.

## D: JSON inventory and decision

| Path | Representation / frequency | Assessment |
| --- | --- | --- |
| Workspace package config | Typed PackageConfigFile; setup/load units | Already avoids generic Value in the main workspace loader |
| Normalized compiler/config identities, workspace discovery/isolation | Value when editing/canonicalizing selected fields | Insertion order matters; do not canonicalize by sorting |
| Builder manifest and AOT/probe/receipt metadata | Typed structs on reuse paths | Keep typed decoding; cold generation has additional Dart JSON work |
| IPC control messages and binary metadata | serde_json Value, then typed metadata where needed | Measure only JSON metadata; raw asset/output bytes are binary |
| Persisted graph | Bounded binary format | Not a JSON bottleneck |
| Serialization | serde_json to_vec/to_writer, preserve_order | Separate from parse/copy kernels |

Real package_config is 14,504 B; builder-manifest is 35,255 B. Final JSON results
use production serde_json **1.0.151**, preserve_order, and simd-json **0.17.3**.
An exploratory run accidentally selected serde_json 1.0.154; it is excluded from
these JSON tables. The evaluation manifest now pins the production version.

| Input / operation | Release us | Native us | Allocations | Peak bytes |
| --- | ---: | ---: | ---: | ---: |
| package config / serde-value | 56.53 | 52.58 | 858 | 77,093 |
| package config / simd-value-copy | 51.26 | 48.42 | 866 | 122,341 |
| package config / serde-typed | 25.80 | 23.67 | 286 | 25,048 |
| package config / serialize | 12.49 | 8.85 | 8 | 24,576 |
| package config / copy | 0.17 | 0.14 | 1 | 14,504 |
| manifest / serde-value | 246.50 | 228.27 | 3,226 | 350,488 |
| manifest / simd-value-copy | 196.27 | 192.34 | 3,235 | 530,919 |
| manifest / serialize | 39.74 | 32.31 | 10 | 98,304 |
| manifest / copy | 0.98 | 0.92 | 1 | 35,255 |

The generic manifest DOM row is an experiment, not the cost of the production
typed manifest reader. Typed package config already achieves larger savings
than switching parsers. A few sub-millisecond startup parses do not justify a
new DOM, mutable-input lifetime and compatibility surface.

A separate Broad diagnostic observed 3,807 incoming frames / 3,359,277 JSON
bytes / 46.5 ms summed parse-and-DOM elapsed intervals. The JSON portions of
3,807 outgoing frames totalled 26,706,096 B / 27.5 ms serialization. These
exclude raw binary asset/output bytes, frame I/O, and caller-side Value
construction. Intervals can overlap across worker threads and are perturbed by
logging; they are not additive critical-path CPU time. Small messages dominate
the count. Dynamic batching can slightly change message counts between runs.

Representative captured IPC and one synthetic repeated-metadata JSON (us):

| Payload | serde Value | simd + copy | Native serde | Native simd | serde / simd peak B |
| --- | ---: | ---: | ---: | ---: | ---: |
| 39 B control | 0.295 | 0.379 | 0.294 | 0.408 | 385 / 1,093 |
| 175 B control | 0.942 | 1.078 | 0.952 | 1.137 | 2,471 / 3,438 |
| 63,557 B metadata | 184.770 | 140.783 | 185.235 | 138.013 | 276,228 / 434,369 |
| 1,044,347 B synthetic | 3,083.226 | 2,768.961 | 3,256.048 | 2,891.286 | 4,413,650 / 6,971,845 |

The 39 B row allocates 6 / 13 times; the 175 B row 18 / 28. SIMD improves larger
DOMs but regresses the common tiny-message shape. A new tokenizer/tape and its
buffers/transitive dependencies would add costs to a path contributing little
to this workload's total. Parser tokenization, DOM construction and string-copy
time are combined by these APIs; only explicit input copying and serialization
are independently measured. Borrowed DOMs and reusable simd-json scratch buffers
were not evaluated, so this is not a best-case SIMD-parser bound.

Compatibility probes compare object order/duplicate keys, escaped and raw
Unicode, surrogate pairs, integer boundaries, floats/negative zero/large
exponents, trailing commas and invalid values. Both agree on tested valid
values and most tested rejection cases. However, simd-json 0.17.3 accepted
`"\uD800"` as a NUL string where serde_json rejected the isolated high surrogate.
It also reports different error locations/types. This observed incompatibility
alone rules out a transparent replacement without additional validation.
No production parser, IPC framing, 256 MiB limit, numeric handling, object
insertion order or malformed-message behavior is changed. Exhaustive parser
fuzzing and typed IPC redesign are not completed.

## CPU implementations and portability

Existing serde_json uses memchr/SWAR scanning. memchr dispatches SIMD at runtime.
The selected BLAKE3 crate supplies runtime x86 dispatch among portable/SSE2/
SSE4.1/AVX2/AVX-512 implementations and AArch64 NEON. All existing distribution
targets remain; the build does not require AVX2 or a host-native CPU.

The evaluated xxhash-rust selects SSE2 for ordinary x86_64 and AVX2/AVX-512
according to compile-time target features; its default API is not claimed to
runtime-dispatch to AVX2. CRC32C 0.6.9 dispatches SSE4.2 CRC32 on x86_64, with
software fallback; AArch64 CRC dispatch is library/cfg dependent and was source
inspected, not executed. This crate does not use PCLMUL/PMULL for CRC folding.
BLAKE3 uses add/xor/rotate SIMD rather than CRC instructions.

Disassembly identifies CRC32 instructions in crc32c's hardware functions and
VPCLMULQDQ in simd-json's AVX2 structural-index scanner (not the CRC candidate).
Native probing also finds POPCNT/LZCNT, while both variants contain TZCNT in
library/hash-table code. Presence in a multiversioned binary does not mean every
host executes that variant; no cross-CPU timing claim follows from disassembly.
A baseline TZCNT mnemonic may represent backward-compatible REP BSF on a known
nonzero value; it is not evidence of a new mandatory BMI requirement. ARM
CRC/PMULL and Windows/macOS execution were not measured locally.

## End-to-end results and limitations

The final campaign rotates baseline/native/proposal order in the same prepared
workspace. Each variant has separately preserved graph/manifest evidence so
schema invalidation is not accidentally timed on every switch. All use the
same copied, immutable AOT executable, SDK, dependencies, two-worker limit and
shared warm analysis cache. Inputs and outputs are restored outside timing.
No compiler, other benchmark or correctness check runs alongside these samples.

Wall seconds, median (min–max):

| Case / samples each | Main | Native main | Proposal |
| --- | ---: | ---: | ---: |
| No-op / 15 | 0.313 (0.300–0.355) | 0.313 (0.300–0.359) | 0.291 (0.277–0.310) |
| One-file / 6 | 0.606 (0.596–0.620) | 0.617 (0.595–0.635) | 0.566 (0.545–0.629) |
| Broad / 3 | 9.026 (8.095–9.581) | 8.266 (7.536–9.546) | 8.256 (8.002–8.364) |

Median aggregate child CPU ms / maximum child RSS KiB:

| Case | Main | Native main | Proposal |
| --- | ---: | ---: | ---: |
| No-op | 352.8 / 59,904 | 356.0 / 59,904 | 328.9 / 59,904 |
| One-file | 654.0 / 87,444 | 667.6 / 87,602 | 613.9 / 87,500 |
| Broad | 17,417.8 / 199,692 | 15,899.3 / 201,272 | 15,921.1 / 202,604 |

The observed median reductions are 6.9% No-op and 6.6% One-file. Proposal wins
14/15 paired No-op repeats and 5/6 One-file repeats; paired median differences
are -26.5 / -38.7 ms. One-file has fewer samples and overlapping ranges.
Broad is noisy, has three repetitions, and earlier rotations showed much
smaller differences. **A consistent Broad improvement is not established.**
The native-only compiler flag is not a general improvement.

Clean controls include cold worker AOT compilation and independent empty shared
caches, one sample each (not rotated):

| Variant | Wall s | CPU ms | Maximum child RSS KiB |
| --- | ---: | ---: | ---: |
| Main | 42.067 | 60,003.9 | 673,332 |
| Native main | 44.125 | 63,179.9 | 680,712 |
| Proposal | 46.030 | 66,278.0 | 694,584 |

The proposal is slower in this single Clean control. This sample cannot
establish causality or exclude a Clean regression; there is **no Clean speedup
claim**. More clean repetitions and production workloads remain useful before
merging. The measured warm improvements are not presented as an AOT compiler
or Dart-builder optimization.

With ordinary launcher AOT selection (no override), an old-format warm workspace
upgrade took 39.858 s / 55,050.4 CPU ms / 682,516 KiB maximum child RSS, including
AOT recompilation and graph rebuilding. The immediately following steady No-op
took 0.300 s / 341.0 CPU ms / 59,904 KiB. Both produced identical outputs. These
are one-sample migration controls, distinct from the repeated explicit-AOT table.
An earlier override-based graph reset took 26.7 s and excluded ordinary AOT
selection; it is not treated as the complete upgrade cost.

All final 72 warm samples had identical generated file sets/bytes across
variants for their case, with 0/1/500 changed public files as appropriate.
All Clean variants generated the same 1,001 files / 8,057,397 B with inventory
SHA-256 `bac1a73eb568b569f5cfc5de90c75234e1ce61ffdf14d8266f42c9c4a3c5c97a`.
A separate clean stock build_runner run also matched all 1,001 output files.

Hash strings grow from 16 to 67 characters. Saved graph files were approximately
4.32 MB main and 4.62 MB proposal; observed graph evidence can also vary with
scheduling, so this is not an isolated equal-record size comparison. Unchanged
maximum child RSS does not prove unchanged Rust heap: the launcher/worker can
be the largest process. No whole-build memory reduction is claimed. The Linux x86_64 Release executable
grows from 4,725,640 to 4,800,504 B (about 75 KB); BLAKE3 adds seven locked package
entries including its build dependencies. JSON evaluation dependencies are isolated
from the distribution.

## Adoption and risk summary

| Candidate | Decision and evidence | Complexity / correctness risk |
| --- | --- | --- |
| Sorted snapshot merge | Adopt; improves all tested context cases without extra allocation | Small; exhaustive reference comparison preserves missing/existence/content semantics |
| String HashMap reverse edges | Defer; real graph faster, tiny graph slower; small E2E contribution | Small implementation, more workload evidence needed |
| Dense/sparse/Roaring IDs | Defer one-shot integration; reuse is fast, conversion dominates this real graph | Larger lifetime/rebuild/unknown-vertex and retained-memory design; prototype seeds are indexed graph vertices |
| BLAKE3-256 internal identity | Adopt; remaining real hash cost and steady E2E reduction | Small algorithm change, medium invalidation surface; larger strings, short-key cost, cold upgrade and old undo refusal documented/tested |
| xxHash3-128 | Not adopted; fastest kernel, while BLAKE3 provides one stronger 256-bit primitive for content, keys and undo evidence | A domain-specific alternative remains possible; no xxHash E2E implementation was measured |
| CRC32C | Reject standalone identity; 32-bit collisions/linearity | Inappropriate correctness boundary, regardless of instruction throughput |
| Streaming file reads | Defer policy change; helps large warm files, larger buffers regress small ones | Requires distribution/threshold and memory-pressure evidence; no production I/O change |
| Typed JSON | Keep existing typed loaders; extend only for demonstrated hot paths | Further IPC changes need schema/error/order validation |
| simd-json | Reject transparent replacement; small-message/heap costs and observed invalid-surrogate acceptance | Buffer reuse/borrowed DOMs and full differential validation remain untested |

## Correctness and reproducibility checks

- `cargo test --locked --manifest-path rust/Cargo.toml`: 230 passed, one ignored.
- `cargo clippy --locked --manifest-path rust/Cargo.toml --all-targets --all-features -- -D warnings`: passed.
- Release build, Rust formatting and `git diff --check`: passed.
- `dart test --compiler=source test/manifest_emitter_test.dart`: three passed.
- `BUILD_RUNNER_ACCELERATOR_BIN=... bash scripts/correctness_commit_recovery.sh`:
  passed publication interruption points, stale deletion, stock byte equality,
  no-op and resident watch I/O failure/rollback/retry.
- 6,561 snapshot-pair differential cases; old schema-7 invalidation preserves
  source/output files; old undo journals are preserved before recovery writes;
  old receipt namespace is not loaded; current corruption/edit tests pass.
- Default SIMD dispatch and forced portable BLAKE3 produced the same tagged
  values for ten lengths from zero through 4 MiB, including 1,023/1,024/1,025-byte
  boundaries. BLAKE3/xxHash/CRC chunked values match one-shot values too.
- Release `cargo check --locked --features blake3/pure` passed for the existing
  five distribution targets. This checks Rust types/fallbacks without C cross
  compilers. **Default-feature native builds/runtime on the other four targets
  are not established by these checks** and remain CI validation. Host default
  SIMD Release and tests are verified.

The complete existing verify/watch/builder matrix is deferred to CI. This
focused validation does not replace every supported builder/platform gate.

## Remaining scope

- Persistent graph ID indexes across watch mutations and their rebuild policy;
  end-to-end graph-filter integration and hardware cache counters. CSR adjacency,
  generation-stamped visited arrays, alternative interner hashers such as AHash,
  and FixedBitSet were not tested; this report does not rule them out.
- Production Flutter apps and graphs with different density/change skew.
- Cold storage and large-file streaming under memory pressure; file-read kernels
  here use a warm page cache. Per-call Dart SHA-256 CPU attribution and alternative
  Dart hashing were not measured.
- Complete JSON parser differential fuzzing, peak process memory by JSON phase,
  typed IPC decoding, and buffer-reuse designs. The evaluated simd-json API
  allocates its parser scratch per call; it is not a best-case reused-buffer claim.
- Native runtime benchmarks on the other four distribution targets and the
  existing long stock/watch compatibility matrix, which remains CI work.

Raw JSON/CSV/logs are intentionally not committed. Reproduction writes new
local artifacts; no unavailable raw-data links are referenced here.

## Reproduction

To reproduce the historical tables, check out measured commit `bd18bee` and use
stable 1.98.1, Dart 3.13.3 and the fixture lockfile. The rebased branch includes
additional main optimizations and is not the measured proposal.
Use a fresh disposable output directory. All raw output belongs outside Git.
Finish builds/checks before any timing; run benchmarks sequentially.

```sh
repo="$PWD"
export CARGO_HOME="$repo/.toolchains/cargo"
export RUSTUP_HOME="$repo/.toolchains/rustup"
cargo="$CARGO_HOME/bin/cargo"
rustc="$CARGO_HOME/bin/rustc"
dart="$repo/.toolchains/dart/dart-sdk/bin/dart"
out=/tmp/bra-bcd-evaluation
mkdir -p "$out"

# Build controls from the exact old main, keeping this checkout intact.
git worktree add --detach "$out/main" 617bb0bf6fba9193527d557c39a7c40ce3730aae
"$cargo" build --locked --release --manifest-path "$out/main/rust/Cargo.toml"
cp "$out/main/rust/target/release/build_runner_accelerator" "$out/baseline"
RUSTFLAGS='-C target-cpu=native' CARGO_TARGET_DIR="$out/native-target" \
  "$cargo" build --locked --release --manifest-path "$out/main/rust/Cargo.toml"
cp "$out/native-target/release/build_runner_accelerator" "$out/native"
"$cargo" build --locked --release --manifest-path rust/Cargo.toml
cp rust/target/release/build_runner_accelerator "$out/proposal"

# The retained baseline workspace supplies real graph/config/manifest inputs.
KEEP_BENCHMARK_WORKSPACE=1 LANE=accelerator COUNT=500 CASES=clean REPEATS=1 \
  ACCELERATOR_JOBS=2 PUB_GET_OFFLINE=0 \
  BUILD_RUNNER_ACCELERATOR_BIN="$out/baseline" RESULTS_DIR="$out/initial" \
  bash scripts/benchmark_current_baseline.sh
# Set work to the retained .../default/r1/clean path printed by the wrapper.
work=/absolute/path/to/retained/default/r1/clean

# Capture schema-7 graph before any proposal build invalidates it.
python3 scripts/perf-kernels/extract_graph.py \
  "$work/.dart_tool/build_runner_accelerator/graph-v3.bin" "$out/resolver.json"
"$cargo" build --locked --release --manifest-path scripts/perf-kernels/Cargo.toml
RUSTFLAGS='-C target-cpu=native' CARGO_TARGET_DIR="$out/kernels-native" \
  "$cargo" build --locked --release --manifest-path scripts/perf-kernels/Cargo.toml
python3 scripts/perf-kernels/compare_context.py --baseline 617bb0b \
  --results "$out/context" --rustc "$rustc"

# After ALL compilation has finished; repeat these in reverse order too.
kernel="$repo/scripts/perf-kernels/target/release/accelerator-perf-kernels"
PERF_GRAPH="$out/resolver.json" "$kernel" graph > "$out/graph.csv"
"$kernel" sets > "$out/sets.csv"
"$kernel" hash "$work/lib/features/feature_001/model.dart" > "$out/hash.csv"
"$kernel" json "$work/.dart_tool/package_config.json" \
  "$work/.dart_tool/build_runner_accelerator/builder-manifest.json" > "$out/json.csv"
"$kernel" stream /absolute/path/to/test-file > "$out/stream.csv"
"$kernel" compat > "$out/compat.log"
for variant in baseline native proposal proposal native baseline; do
  "$out/context/$variant" >> "$out/context-$variant.csv"
done
```

Diagnostics are a separate source copy. `profile.py` records FNV call sites,
scan reads, incoming JSON parsing and outgoing JSON serialization. Its optional
`PERF_JSON_DIRECTORY` captures incoming JSON metadata/control only. It never
writes raw binary asset/output bodies to those JSON files. Build the copy
before running it; never use its timings as instrument-free E2E observations.

```sh
python3 scripts/perf-kernels/profile.py "$out/profile-src" --revision 617bb0b
"$cargo" build --locked --release --manifest-path "$out/profile-src/Cargo.toml"
# Run this binary on a separately prepared diagnostic fixture with
# BUILD_RUNNER_ACCELERATOR_WALL_TRACE=1 and PERF_JSON_DIRECTORY set to an
# existing local directory. Do not run a timed campaign concurrently.

python3 scripts/perf-kernels/migration.py --workspace "$work" \
  --baseline "$out/baseline" --proposal "$out/proposal" --dart "$dart" \
  --pub-cache "$repo/.pub-cache" --cache "$work.shared-cache" \
  --results "$out/migration"
cp -L "$work/.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker" \
  "$out/fixed-worker"
python3 scripts/perf-kernels/paired_warm.py --workspace "$work" \
  --repository "$repo" --baseline "$out/baseline" --native "$out/native" \
  --proposal "$out/proposal" --worker-aot "$out/fixed-worker" \
  --cache "$work.shared-cache" --dart "$dart" --pub-cache "$repo/.pub-cache" \
  --results "$out/paired" --noop-repeats 15 --edit-repeats 6 --broad-repeats 3
```

`digest_vectors` can be run with default features and with
`--features blake3/pure,blake3/no_sse2,blake3/no_sse41,blake3/no_avx2`; compare
stdout. This checks values, not portable-backend throughput. For allocator and
JSON compatibility details inspect the standalone kernel sources. The eval
package and its lockfile do not add simd-json/CRC/xxHash/Roaring to production.
