# Graph, hash and JSON performance

Adopt ordered snapshot comparison and BLAKE3-256 internal hashes. In the
500-feature mixed app, median No-op improves **7.8%** and One-file **7.9%**.
Clean has no demonstrated improvement. **Broad's median is 7.2% slower; its
regression risk remains unresolved.** Graph representation and JSON parser
replacements are not adopted.

## Build results

Measured main `5ae9ee8`, proposal `e064e57`; both include #163. Linux x86_64 KVM,
Xeon Platinum 8573C, three visible CPUs with a two-CPU quota, 8 GiB memory;
2026-11-06. Stable Rust 1.98.1, Dart 3.13.3, two workers, launcher included.
The locked 500-feature app uses Freezed 4.0.1, Riverpod generator 4.0.9,
json_serializable 6.14.1 and build_runner 2.16.2, producing 1,001 files.

All compilation finishes before timing; diagnostics and other validation are
stopped. Each group rotates all six permutations of normal main Release,
evaluation-only `target-cpu=native` main, and portable proposal Release.
Clean uses independent workspaces/empty shared caches and includes AOT compilation;
Pub resolution is outside timing and OS page caches are not flushed.
Warm cases share one immutable AOT executable, checked after each run, with
variant-specific graph/manifest snapshots. Base inputs are restored and rebuilt
outside timing before edits. Existing FVM pruning, resolver-aware scheduling,
digest reuse and directive caching remain enabled.

Wall seconds, median (minimum–maximum):

| Case / samples each | Main | Native main | Proposal |
| --- | ---: | ---: | ---: |
| Clean / 6 | 45.571 (44.071–46.050) | 44.780 (43.945–45.440) | 45.794 (44.208–46.995) |
| No-op / 30 | 0.313 (0.296–0.330) | 0.314 (0.299–0.352) | 0.288 (0.276–0.343) |
| One-file / 12 | 0.607 (0.590–0.626) | 0.610 (0.593–0.649) | 0.559 (0.547–0.586) |
| Broad / 6 | 8.987 (8.331–15.198) | 9.630 (8.754–10.397) | 9.637 (7.917–15.565) |

Proposal wins 28/30 paired No-op rounds and 12/12 One-file rounds; median paired
changes are −21.9/−45.0 ms. Clean is 0.5% slower with 3/6 wins; Broad has 2/6 wins
and a +315 ms median paired change. All **162 samples** match generated file
sets/bytes, with 0/1/500 changed outputs for No-op/One-file/Broad.

Median CPU seconds / maximum child RSS MiB:

| Case | Main | Native main | Proposal |
| --- | ---: | ---: | ---: |
| Clean | 65.593 / 663.22 | 63.925 / 662.89 | 65.865 / 661.53 |
| No-op | 0.356 / 58.50 | 0.358 / 58.50 | 0.330 / 58.50 |
| One-file | 0.654 / 84.87 | 0.660 / 84.88 | 0.608 / 84.86 |
| Broad | 17.355 / 199.10 | 18.622 / 194.99 | 18.632 / 193.67 |

CPU is user plus system time. RSS is a child-process high-water mark, not
aggregate process-tree memory or Rust heap; no memory reduction is established.

Three ordinary-launcher upgrades, without a worker override, take median
**40.388 s (39.170–43.518)**. Each invalidates schema 7 and recompiles AOT.
Immediately following No-ops take **0.290 s (0.284–0.354)**, versus main's
**0.321 s (0.304–0.327)**. All nine runs preserve output bytes. This small control
separates upgrade cost from steady state; it is not an additional speedup claim.

### Broad diagnosis

Four instrumented builds use the same fixture/AOT with metrics and wall traces,
in main/proposal then proposal/main order. These are separate from E2E timings.
Rust trace seconds, excluding the launcher:

| Pair | Main total / execution | Proposal total / execution |
| --- | ---: | ---: |
| Main then proposal | 9.418 / 9.069 | 8.446 / 8.143 |
| Proposal then main | 8.815 / 8.461 | 9.542 / 9.241 |

The sign reverses; the difference lies inside builder execution. Work outside
execution is 46–53 ms shorter on proposal. Dirty checking is 73–75 → 65–66 ms,
commit about 180 → 156 ms, and graph saving remains 8–9 ms.
All runs execute 2,004 actions; diagnosed runs have six resolver resets, zero
directive-cache misses and 100% byte-store hits. All four match output bytes.
Adaptive batching changes worker assignments and analysis reuse between runs;
this is a variability candidate, not a proven cause. No production regression
has been isolated or fixed, and Broad's risk remains open.

## Candidate decisions

### B: graph and set processing

`GraphState::dirty_context` merges ordered snapshots instead of looking up each
key in both trees. Existence/digest semantics, size-only behavior, reverse
propagation and #163's empty-change shortcut are preserved. Exact function-body
kernels against current main use identical inputs, seven batches and two
order-reversed passes; separate untimed calls count allocations/peak live heap.
Fixed 16-character digests isolate the comparison algorithm; E2E includes actual
BLAKE3 strings. Representative times are microseconds:

| Entries / case | Main | Native main | Merge | Allocations / peak bytes, all variants |
| --- | ---: | ---: | ---: | --- |
| 64 / No-op | 3.42 | 3.46 | 0.59 | 0 / 0 |
| 4,096 / No-op | 795.06 | 818.17 | 53.46 | 0 / 0 |
| 32,768 / No-op | 7,490.39 | 7,335.55 | 694.99 | 0 / 0 |
| 4,096 / last-entry change | 2,057.68 | 2,003.04 | 1,242.54 | 4,790 / 647,600 |
| 32,768 / disjoint snapshots | 45,124.27 | 42,765.78 | 40,326.26 | 38,274 / 11,805,104 |

All 12 tested size/case combinations improve; this does not imply a Broad E2E
improvement. The main correctness risk is missing additions/removals at iterator
tails; exhaustive snapshot-pair tests cover it.

Representation experiments use the initial `617bb0b`/`bd18bee` investigation,
not the current-main E2E baseline. The real resolver graph has 1,787 nodes and
3,706 edges. Synthetic inputs cover 64/4,096/32,768 nodes, degree 2/32,
duplicates, shared dependencies, one seed and 10% seeds.

| Representation / real last-key seed | Time us | Allocations / peak bytes | Decision |
| --- | ---: | ---: | --- |
| String BTree reverse adjacency | 524.6 | 1,588 / 258,776 | Retain |
| String HashMap | 326.5 | 1,391 / 245,584 | Defer: tiny graph regresses 6.06 → 7.92 us |
| Dense IDs, rebuild / reuse | 618.5 / 5.1 | 1,402 / 219,400; 16 / 33,040 | Defer: conversion dominates one traversal |
| Sparse IDs, rebuild / reuse | 682.6 / 30.3 | 1,410 / 228,408; 24 / 42,048 | Defer |
| Roaring, rebuild / reuse | 654.9 / 27.0 | 1,411 / 221,384; 25 / 35,024 | Defer |

Index construction alone costs 628.5 us. Persistent IDs need an invalidation and
retained-memory design. Set duplicate/union/intersection/filter kernels also show
reuse benefits but conversion regressions on small/sparse inputs. No heuristic
threshold or all-pairs matrix is introduced.

### C: hashes and cache correctness

The initial instrumented No-op attributes about 41.3 ms to 8,810 hash/format calls
over 31.28 MB (median 1,991 B, p90 11,959 B, max 76,923 B). Initial scan reads
separately take 52.0 ms for 2,004 reads/9.26 MB, excluding other reads. Existing
AOT receipts, digest reuse and output-read deduplication already avoid work;
these diagnostics measure remaining calls and are not E2E latency observations.

| Use | Resulting algorithm / treatment |
| --- | --- |
| Rust snapshots, change detection, output reuse, cache/config/AOT keys | Full tagged BLAKE3-256 replaces FNV-1a-64 |
| Publication undo verification | BLAKE3 for new journals; existing FNV journal rollback precedes cache invalidation |
| Dart/Rust worker-source identity | Separate FNV contract, unchanged |
| Dart content/resolver/directive/factory digests | SHA-256, unchanged |
| Analysis byte-store fingerprint / public builder digest | Truncated 64-bit SHA-256 / build_runner-compatible MD5, unchanged |
| Release integrity and authentication | SHA-256/signatures, unchanged |

| Candidate / kernel evidence | Decision and tradeoff |
| --- | --- |
| BLAKE3: 11,959 B generated file 15.69 → 4.72 us including formatting | Adopt; 16 B keys regress 0.083 → 0.136 us |
| xxHash3-128: same file 0.62 us | Defer; fastest kernel, noncryptographic; no xxHash E2E measured |
| CRC32C: raw 4 MiB 182 us | Reject as sole identity: 32-bit, linear, forgeable |
| Streaming BLAKE3: 4 MiB full/64 KiB stream 1,248/1,073 us | Defer: 1,989 B file regresses 3.51 → 4.60 us and uses a 64 KiB buffer |

Tests include short/large/real inputs, streaming equality and two-thread hashes
of independent messages with thread startup included. No I/O/thread policy changes.
BLAKE3 strings grow 16 → 67 characters; observed graphs grow about 4.32 → 4.62 MB
with scheduling-dependent record differences. The initial Linux binary grows
about 75 KB and adds eight locked dependency entries.

For n independent BLAKE3 values, birthday collision probability is approximately
n(n−1)/2^257; generic collision/preimage resistance is about 2^128/2^256.
This is not cache authentication: receipts assume trusted local metadata.
Schema 8, tagged keys and the BLAKE3 receipt namespace invalidate obsolete state.
Pending publication evidence is fully validated and rolled back before cache
regeneration; new writes keep BLAKE3. Backup checks and release authentication
are preserved.

### D: JSON and configuration

Workspace config and manifest/cache loaders already use typed deserialization;
selected normalization and IPC control paths use ordered `Value`. Graph state
and asset/output bodies are binary. An initial Broad diagnostic attributes
46.5 ms to 3,807 incoming JSON parses (3.36 MB) and 27.5 ms to outgoing JSON
serialization (26.71 MB), excluding binary bodies, I/O and caller-side DOM
construction. These perturbed, overlapping intervals are not critical-path CPU.

| Kernel | serde_json / simd-json time us | Peak bytes | Decision |
| --- | ---: | ---: | --- |
| Package config DOM | 56.53 / 51.26 | 77,093 / 122,341 | Keep existing typed loader: 25.80 us, 25,048 B |
| 39 B IPC control | 0.295 / 0.379 | 385 / 1,093 | Keep serde_json; SIMD adds copies/allocations |
| 63,557 B metadata | 184.77 / 140.78 | 276,228 / 434,369 | Larger DOM improves, but is not the dominant shape |

simd-json 0.17.3 accepts an isolated `"\uD800"` as NUL where serde_json 1.0.151
rejects it, preventing transparent replacement. Probes also cover order/duplicate
keys, numbers, Unicode, escapes and malformed input; full differential fuzzing is
unfinished. Parse/DOM/string construction remain combined by these APIs; explicit
copying and serialization are measured separately. Reusable parser buffers and
borrowed DOMs remain untested. IPC framing/256 MiB limit and error behavior stay
unchanged. No parser dependency is added to production.

## CPU support and verification

BLAKE3 uses library runtime x86 portable/SSE2/SSE4.1/AVX2/AVX-512 dispatch and
AArch64 NEON. Existing memchr uses SIMD dispatch; serde_json uses memchr/SWAR.
The evaluated xxhash-rust selects SIMD through compile-time features. crc32c
0.6.9 has x86 SSE4.2 CRC32 dispatch/software fallback, not PCLMUL/PMULL folding.
Disassembly finds CRC32, TZCNT, native POPCNT/LZCNT, and VPCLMULQDQ in simd-json's
AVX2 scanner. Presence does not prove every host executes those variants;
POPCNT alone does not accelerate membership, and hardware cache counters were
unavailable. No custom intrinsics, global native flags or new CPU requirements.

Stable Rust and all five distribution targets are retained. Host default Release
is verified; five-target Rust checks with `blake3/pure` do not establish native
execution on other platforms. ARM CRC/PMULL throughput remains unmeasured.

- Rust: 235 tests passed, three ignored; formatting and all-feature/all-target Clippy passed.
- 6,561 snapshot-pair comparisons; obsolete cache invalidation; interrupted FNV
  rollback; damaged-backup/external-edit protection; malformed obsolete graph rejection.
- Publication/watch failure, rollback/retry and dart2js/DDC lifecycle checks pass;
  initial stock comparison matches all 1,001 generated files.
- Default/portable BLAKE3 values match through 4 MiB and chunk boundaries;
  FNV/BLAKE3/xxHash/CRC streaming results match whole inputs. Manifest tests pass.

Remaining work: Broad attribution; persistent graph indexes/CSR/interner policy;
other production graphs/Flutter apps; cold storage and memory pressure; Dart
SHA-256 attribution; typed IPC/buffer reuse/fuzzing; other-platform runtime and
full builder/watch CI coverage. None is ruled out by these experiments.

## Reproduction and further measurement

- [Full kernel tables and initial commands](https://github.com/ikesyo/build_runner_accelerator/blob/797cc2da8af68c8d1226b195ce44bee794ed68a1/docs/benchmarks/graph-hash-json-2026-11/README.md).
- [Current-main conditions and full-campaign commands](https://github.com/ikesyo/build_runner_accelerator/blob/797cc2da8af68c8d1226b195ce44bee794ed68a1/docs/benchmarks/graph-hash-json-2026-11/remeasurement.md#reproduction).
- [Kernel evaluation code](https://github.com/ikesyo/build_runner_accelerator/tree/37c01949a4d268afd51ad5bbd6b784a9e2f86290/scripts/perf-kernels)
  and [E2E harnesses](https://github.com/ikesyo/build_runner_accelerator/tree/f9c1bce9b2e71334b129a5fb51a1eaa961a2edf2/scripts/perf-kernels).

Further measurements update this report. Start with the affected case on main
and proposal, two order-reversed pairs, reusing binaries/fixture/AOT. Add native,
Clean/upgrade or more repetitions only for a specific unresolved question.

## Follow-up: repeated constants and configuration work (2026-11-07)

Baseline: latest main `8728af5`, including merged #164 (`1d6c7ca`, final
head `76dbf94`) and #166. The #164 final diff changes internal identities to
BLAKE3, preserves worker-source FNV and adds legacy-journal rollback; this
follow-up preserves those digest/worker-source/journal contracts. The user
subsequently authorized changing the AOT key, allowing the redundant lock digest
to be removed; existing AOT cache slots must be regenerated. Historical 2,004-placeholder / nine
configuration-hash diagnostics are **not** current savings measurements.

### Inventory and decisions

Counts below describe call paths, not a new instrumented whole-build profile.

| Candidate / code | Repeated work and lifetime | Decision / correctness boundary |
| --- | --- | --- |
| `build/planning.rs::create`, `<planned>` (9 B) | One hash, hex conversion and allocation per declared normal output, including stale-output retries; already-present entries discard the result; missing entries previously also clone it | Adopt one local template before the retry loop, clone only for absent/missing entries. Same exists/digest/size; preserve primary provenance, phase visibility and stale-output convergence. One 67-byte template string per call plus inserted-marker clone allocations; zero-output calls now pay one otherwise unnecessary digest. No process cache or shared ownership type |
| `snapshot.rs::scan_packages`, `<virtual-primary>` (17 B) | Four hashes per scanned package; snapshot already retains these entries | Defer: small fixed count in ordinary single-root builds; no evidence justifying a broader constant facility |
| `<missing>` (9 B): `assets.rs`, `build/filtered.rs`, `worker/asset_rpc.rs`, `worker/lazy.rs` | Per newly recorded missing dependency/read; tracked snapshot and read evidence already deduplicate many repeats | Defer: absent-input frequency is workload dependent. A process-wide marker would span unrelated owners; no measured hot path requiring it |
| `workspace.rs::load` | Ordinary path reads/parses the same original config in runner preparation, compiler resolution and source resolution (three times). The latter two are one preparation unit | Adopt parsed-config reuse only when effective and original **path values** agree: three reads/parses become two. Runner preparation remains fresh. Both maps and URI resolution remain separate; add name copies, avoid a second file buffer/JSON parse. Patched/isolation paths still read original source resolution separately |
| `runner_compatibility.rs::prepare` / compile isolation | DOM parse selects and validates effective compiler configuration; Workspace then uses a typed parse | Keep this remaining parse boundary: returning another representation from compiler preparation would broaden its API and ownership for a small saving; patched content must remain distinct from builder-visible inputs |
| `workspace.rs::stable_package_config_identity` | One sorted, normalized typed identity per Workspace; borrowed by manifest/AOT metadata and keys | Already reused. Keep language/package URI, isolation and config-version semantics; do not substitute raw JSON or resolved-location identity |
| `assets.rs::config_digest`, `build.rs` | Raw build.yaml/package_config plus builder fields/options. Ordinary root-only build: once; filtered checks plus preflight can make up to three calls | Keep. Preflight stores its digest and plan; execution recomputes and compares before reuse. Reusing it unconditionally could hide changes during frontend/worker setup. No JSON parsing of config here; builder options serialize per call |
| `frontend.rs::settings_fingerprint`, `Workspace::builder_manifest_fingerprint` | Settings wraps one manifest fingerprint; generation refreshes it (up to two retries). AOT key separately calls manifest fingerprint. Each manifest fingerprint rereads lock, package graph, package build.yaml/pubspec files and normalizes line endings | Keep fresh filesystem observations across generation/compile boundaries. These identify different domains from the graph config and package-resolution keys; they cannot be substituted for each other |
| `manifest_generator.rs::package_resolution/cache_key` | Read JSON, canonicalize roots, serialize normalized DOM and ordered locations, two distinct digests per key; one key on hit, another after compilation on miss | Keep content and location identities separate, including JSON ordering, URI bases, workspace-root normalization and fallback behavior. The postcompile key check prevents publication under changed inputs |
| `worker_kernel.rs::aot_cache_key` lock component | Manifest fingerprint already includes normalized lockfile bytes; the old key separately rereads, normalizes and hashes that same file | Adopt removal of the redundant lock component, with user authorization to change AOT keys. Manifest lock reads now propagate non-NotFound errors for every caller; missing and empty files remain distinct. Remove the duplicate optional-file digest/normalization helpers. Old metadata/key slots are rejected and regenerated without a legacy reader or new metadata schema |
| `worker_kernel.rs::build_aot_metadata/aot_metadata_is_current` | SDK version/experiments, manifest, lock, worker and package identities; SDK/worker checked again in validation and after compile. Context retains cache key (shared-cache directory names rehash it on restore/publication); Workspace retains package identity; validated-digest receipts reuse unchanged file hashes | Keep validation, dependency digests, artifact binding, lock-winner rechecks and publication gates; defer an extra cached directory-name field for miss/wait-only repeats. SDK/worker may change while waiting/compiling. Kernel/manifest/AOT metadata serve separate purposes |
| `worker/pool.rs::ensure_initialized` | Retains workspace/config/artifact initialization signature and resident workers | Already reuses identity/state within compatible watch iterations; do not extend across incompatible SDK/artifact/configuration boundaries |

Ordinary commands load a fresh Workspace. Watch also loads one each cycle,
including when it retains the manifest configuration; the new parsed view never
escapes that Workspace preparation. Config/dependency resolution changes therefore
reload on the next preparation. Selected settings, package graph, SDK and worker
changes retain their existing fingerprint, artifact validation and pool-reset
boundaries. No cached digest is newly passed across a filesystem revalidation.
AOT lockfile handling now reads and normalizes once per key instead of twice,
and hashes it only as part of the manifest fingerprint. With the resolved fixture
this removes one read, one normalization buffer/copy and one BLAKE3/hex/String
operation over a 12,196-byte lockfile. A final targeted kernel characterizes
this removed operation below; there is no additional E2E campaign or speed claim. Missing
and empty locks remain distinguishable; CR/LF/CRLF normalization is unchanged.
Non-NotFound read errors now also fail the standalone manifest fingerprint rather
than being silently omitted. All generation, SDK/worker/dependency validation and
postcompile publication checks remain in place. Existing AOT keys/metadata and
shared slots no longer match and incur an ordinary recompilation or new-key
shared-cache restore; there is no migration/legacy layer. Other identities retain
their values. The existing key shape already separates old/new entries, so no
extra schema/version machinery is necessary.

Public builder digests, release integrity/signatures, journal recovery, dependency
recording and all-success publication are untouched. Stable Rust and the five
existing distribution targets acquire no new dependencies or platform code.

### Minimal measurements

Same Linux x86_64 Xeon Platinum 8573C, two-CPU quota, Rust 1.98.1 stable,
Dart 3.13.3, default portable Release profile/CPU dispatch. All compilation and
other verification stop before timings. No native/Clean campaign or E2E timing
is justified by these sub-millisecond candidates.

Existing `planning_retention_benchmark`, main then proposal / proposal then main,
two samples each; 250/500 source inputs, four actions and eight declared output
visits per input. No worker, launcher or IPC is in this fixture. Untimed serialized
plan/dirty/index dumps match byte-for-byte at both sizes.

| Inputs / marker calls before → after | Main planning µs (range) | Proposal planning µs (range) |
| --- | --- | --- |
| 250 / 2,000 → 1 | 6,813 (6,473–7,153) | 5,956 (5,657–6,255) |
| 500 / 4,000 → 1 | 13,079.5 (12,499–13,660) | 12,328 (11,971–12,685) |

These two-sample medians are noisy function timings, **not build speedups**.
They compare only the planning change; Workspace construction is outside its timer.

Separate `rustc -O` kernels use `black_box` inputs/results, five batches of
100,000 operations, dropping each returned object inside the loop. Median ns
(min–max): hash only **70.3 (67.2–78.7)**; precomputed hash to hex
**24.5 (22.7–28.1)**; precomputed hex into a tagged, capacity-67 String
**15.9 (15.7–17.7)**; actual `digest_bytes` **115.1 (114.0–124.6)**;
67-byte String clone **21.0 (19.0–21.7)**. Components are isolated experiments,
not additive attribution. At 2,004 output visits this suggests roughly
**0.19–0.23 ms** less marker work, depending on existing entries; this is a
kernel-based scale estimate, not a strict latency bound or an E2E observation.
The snapshot strings still require allocation/copy when inserted.

Resolved `json_serializable_app` config: **11,125 B / 54 packages**.
The same fixture has a 106-byte build.yaml; SDK version/allowed-experiments
inputs are 7/380 bytes. Other combined identities scale with builder/package
metadata and are not separately timed because their domains cannot be merged.
Warm `fs::read`: **2.383 µs (2.354–2.398)**; typed `PackageConfigFile`-shape
`serde_json::from_slice` including destruction: **15.087 µs (14.537–15.265)**;
54 additional name clones into a temporary Vec: **1.750 µs (1.745–1.810)**.
These characterize the removed read/parse and added copies, not the duration of
Workspace load. Rough net scale is 16 µs per ordinary preparation, not nine
hashes × an old diagnostic time. A generic JSON DOM costs 45.715 µs here;
**that larger number is not the typed-parser saving**. Normalization/serialization
and hashes remain unchanged for parsed-config reuse, so further microprofiling
those operations was unnecessary.

A final isolated AOT kernel measures the removed `fs::read` → old
`normalize_text_bytes` → current `digest_bytes` chain, including buffer/result
destruction: **18.991 µs (18.805–19.756)** for the 12,196-byte fixture lockfile,
five batches of 10,000 operations. Verification and compilation are stopped
first. This is the scale of one removed operation per AOT key, not a build
latency result or a strict wall-time bound; filesystem/page-cache costs vary.

### Reproduction and validation

Save normal main Release and Release test executables before editing, using the
same Cargo/Rust toolchain/cache; build the proposal before timing. With each
version's emitted test executable copied to `/tmp/main-tests` and
`/tmp/proposal-tests`:

```bash
cargo build --locked --release --manifest-path rust/Cargo.toml
cargo test --locked --release --manifest-path rust/Cargo.toml --no-run
python3 scripts/benchmark_plan_retention.py \
  --baseline-bin /tmp/main-tests --candidate-bin /tmp/proposal-tests \
  --inputs 250 500 --repeats 2
```

For the isolated kernels, link the same Release `blake3`, `serde_json` and
`serde` rlibs with stable `rustc -O`, use `std::hint::black_box` around inputs
and results, and measure five loops of 100,000 operations with `Instant`.
Operations are `blake3::hash(b"<planned>")`, precomputed `Hash::to_hex`,
`String::with_capacity(67)` + `push_str("b3-")` + precomputed hex,
`digest_bytes(b"<planned>")`, and the resulting String's `clone`.
For JSON, deserialize into the exact fields/types/serde attributes of
`workspace.rs::PackageConfigFile/PackageConfigEntry`; separately time
`fs::read` of the resolved fixture config and cloning the 54 names. Exclude
file setup and precomputed values from timers. For the AOT kernel, use the
normalization function from main `8728af5` and time `fs::read` → normalization →
`digest_bytes` on `fixtures/json_serializable_app/pubspec.lock`, five batches of
10,000 operations, dropping all buffers/results per iteration. Do not run compilation or other
verification concurrently. Config size can vary with local package paths.

Validation:

- Stable Release build, Rust **249 passed / three ignored**, all-target/all-feature
  Clippy with `-D warnings`, formatting and `git diff --check` pass. The strengthened
  AOT metadata acceptance/rejection test also passes separately after the full run.
- `bash scripts/verify.sh` passes for the initial two changes. The subsequent
  `VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh` uses the final Release for
  every native invocation and passes all common checks plus every arbitrary-builder
  case. Both reuse the built frontend via `BUILD_RUNNER_ACCELERATOR_BIN`.
- Stock/native output bytes and No-op match; manifest snapshot relocation, code/
  config/SDK changes, corrupt/unavailable caches and AOT/JIT/background/explicit
  modes pass. Upgrade, trigger incremental/delete/rename/failure and arbitrary
  builder/output-conflict checks pass.
- Added coverage: absent/missing/present generated primaries feeding later phases;
  fresh ordinary compiler/source resolutions across config changes; lockfile
  missing/empty/content/line-ending semantics, valid new metadata versus rejected
  old-key metadata, and read-error failure. Existing compiler-isolation, patched
  source visibility, SDK/worker invalidation and recovery unit tests pass.
- Full watch/builder suites and native execution on the other four distribution
  targets remain CI work; no cross-platform runtime or E2E speed claim is made.

Raw kernel sources, JSON dumps and logs stay outside the tracked tree.
