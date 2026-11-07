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

Against main `8728af5` (including #164 and #166), adopt local planning-marker
and virtual-primary reuse, parsed package-config reuse and removal of redundant
AOT lock/package-config components.
These remove small repeated operations; **no E2E speedup is established**.
Historical 2,004-placeholder / nine-configuration-hash diagnostics are not current
savings measurements.

### Candidate decisions

Counts describe call paths, not an instrumented whole-build profile.

| Candidate / code | Repeated work | Decision and boundary |
| --- | --- | --- |
| `<planned>`, `build/planning.rs::create` | Hash/format per declared normal output, including stale-output retries; present entries discard it | Adopt one local template per call, cloning only for absent/missing entries. Preserve phase visibility and retries; inserted strings still allocate. Zero-output calls now pay one extra digest |
| `<virtual-primary>`, `snapshot.rs::scan_packages` | Four hashes per scanned package | Adopt one lazy template per scan: 4 × packages → one hash, or zero for no packages. Local 67-byte string plus insertion clones; no global state |
| `<missing>`, `assets.rs`, `build/filtered.rs`, `worker/{asset_rpc,lazy}.rs` | Per newly recorded dependency/read, with existing deduplication | Defer: unknown remaining repetition; retaining a template adds a copy when used only once |
| `workspace.rs::load` | Ordinary config read/parse in runner preparation, compiler resolution and source resolution: three times | Adopt parsed reuse when effective/original paths agree: three become two. Patched/isolation source resolution stays separate; add name copies instead of another read/parse |
| `runner_compatibility.rs::prepare`; `Workspace::package_config_identity` | Preparation DOM and Workspace typed parse remain separate; normalized identity is computed once per Workspace | Keep existing digest reuse. DOM→typed conversion loses duplicate-field rejection; isolation cache hits return a validated file rather than the effective DOM. Sharing parsed data needs a coordinated return-type/validation change |
| `assets.rs::config_digest`, `build.rs` | Once in ordinary root-only builds, up to three times with filtered checks/preflight | Keep execution-time comparison with the stored preflight digest; unconditional reuse could hide changes during setup |
| `frontend.rs::settings_fingerprint`, `Workspace::builder_manifest_fingerprint`; `manifest_generator.rs::package_resolution/cache_key` | Settings refreshes after generation; package-resolution key recomputes after compilation on a miss | Keep fresh observations and distinct raw-config, normalized-content and resolved-location identities, including JSON order and URI-base semantics |
| `worker_kernel.rs::aot_cache_key` lock/package components | Manifest fingerprint already includes normalized lock bytes and the exact package-config identity | Adopt removal of both duplicate components. Lock removal saves read/normalize/hash; package removal saves 76 key bytes, with no extra read/hash saved. Lock read errors propagate; missing/empty remain distinct. Old AOT slots regenerate |
| AOT metadata validation, `worker_kernel.rs`; initialization signature, `worker/pool.rs` | SDK/worker/dependency checks repeat across waiting/compilation; context, receipts and resident pool already retain compatible identities | Keep revalidation/publication gates and existing reuse. Defer another cached directory-name field for miss/wait-only repeats |

Reuse stays within one preparation: commands and watch cycles load fresh
Workspaces. Generation/compilation rechecks, config/dependency/SDK/worker change
detection, dependency recording and all-success publication remain intact.
BLAKE3-256 tags/values and worker-source/public-builder/release verification
contracts are unchanged; only the AOT key shape changes. Lock read errors now
also fail standalone manifest fingerprinting rather than being silently omitted.
No process cache, shared ownership type, new dependency or platform code is added.

### Measurements and limits

Linux x86_64 Xeon Platinum 8573C, two-CPU quota, stable Rust 1.98.1, Dart 3.13.3,
default portable Release. Compilation and verification stop before timing.
The existing planning fixture uses main/proposal then proposal/main, two samples
each; no worker, launcher or IPC. Untimed plan/dirty/index dumps match byte-for-byte.

| Inputs / marker calls before → after | Main planning µs (range) | Proposal planning µs (range) |
| --- | --- | --- |
| 250 / 2,000 → 1 | 6,813 (6,473–7,153) | 5,956 (5,657–6,255) |
| 500 / 4,000 → 1 | 13,079.5 (12,499–13,660) | 12,328 (11,971–12,685) |

These noisy two-sample medians cover only planning, not Workspace construction
or build latency. Additional virtual-marker/package-component changes are assessed
by removed work only. Separate `rustc -O` kernels give these scales:

| Operation / input | Median kernel time | Interpretation |
| --- | --- | --- |
| 9 B marker: hash / hex / tagged String allocation / full digest / clone | 70.3 / 24.5 / 15.9 / 115.1 / 21.0 ns | Components are not additive. About 0.19–0.23 ms less marker work at 2,004 visits, depending on existing entries |
| Config: 11,125 B, 54 packages; read / typed parse / additional name copies | 2.383 / 15.087 / 1.750 µs | Rough net scale of 16 µs per ordinary preparation; not a Workspace-load timing |
| Lock: 12,196 B; removed read/normalize/digest chain | 18.991 µs (18.805–19.756) | One removed operation per AOT key |

These are kernel-based scale estimates, not strict latency bounds. Filesystem
costs vary; no additional Clean/native/E2E campaign or memory claim is justified.

### Reproduction and validation

Build main and proposal Release/test executables with the same toolchain/cache,
copying their emitted test binaries to the paths below before comparing:

```bash
cargo build --locked --release --manifest-path rust/Cargo.toml
cargo test --locked --release --manifest-path rust/Cargo.toml --no-run
python3 scripts/benchmark_plan_retention.py \
  --baseline-bin /tmp/main-tests --candidate-bin /tmp/proposal-tests \
  --inputs 250 500 --repeats 2
```

Isolated kernels link the same Release rlibs with `rustc -O`, use `black_box`
inputs/results and `Instant`, and drop results inside each iteration. Use five
batches of 100,000 operations for marker components, config read, typed
`PackageConfigFile` parse and name clones; five of 10,000 for lock read → main
`8728af5` normalization → `digest_bytes`. Exclude setup and concurrent work;
fixture config size depends on local paths.

- Release build, Rust **249 passed / three ignored**, final focused AOT metadata
  test, formatting, all-target/all-feature Clippy and `git diff --check` pass.
- The initial implementation passes both `scripts/verify.sh` variants, including
  `VERIFY_ARBITRARY_BUILDER=1`. Later virtual-marker/package-key changes pass
  `bash scripts/smoke.sh`; stock/native bytes and No-op match.
- Coverage includes generated-primary visibility, config reload/AOT key sensitivity, patched/isolation
  source separation, lock missing/empty/content/newline/error behavior, new/old
  AOT metadata, cache/SDK/worker changes, upgrade and incremental/delete/rename/
  failure/output-conflict paths. Full watch/builder suites and other-platform
  native execution remain CI work. Raw data/tools are not in the tracked tree.
