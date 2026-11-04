# SIMD and CPU-extension investigation

The final changes improve scanner latency and avoid no-op reverse-graph allocations.
**The mixed-application results do not establish a substantial end-to-end speedup.**

Baseline: `617bb0b` (main fetched on 2026-11-04). This investigation does not
repeat `.fvm/flutter_sdk` discovery pruning, resolver-aware scheduling, output
digest deduplication, directive-parse caching, or validated AOT digest reuse.

## Pipeline and existing optimizations

Rust loads workspace/configuration and the binary graph, snapshots eligible
assets, plans actions, checks changes, then orchestrates resident Dart workers
and publishes the successful transaction. Analyzer, builders and most Dart
directive/annotation parsing remain in Dart. Existing `WALL_TRACE`, worker
metrics, `measure_process.py`, and `benchmark_current_baseline.sh` support
separate diagnostic and elapsed-time runs. Timing disables all trace metrics.

The pinned toolchain is stable Rust 1.98.1, edition 2024. Cargo's normal release
profile uses LLVM optimization level 3; no release-wide CPU feature or LTO
setting is introduced. CI builds the existing five Linux/macOS/Windows targets.

## Candidates

| Area / code | Current implementation and CPU support | Proposed approach / evidence needed | Cost and risk / decision |
| --- | --- | --- | --- |
| `build/part_directive.rs::declares_part_directive` | Scalar byte-offset loop, four-byte `part` comparison; conservative lexical pre-filter, not a Dart parser | Reuse one SIMD-dispatched `memmem::Finder` for the fixed keyword, retaining the direct-match fast path; compare native LLVM, one-byte and fresh-finder prototypes | Small, one already-transitive dependency made explicit; preserve every existing parse decision |
| `lib/src/trigger_evaluator.dart`, `worker_analysis_driver_model.dart` | Official BuildTrigger/Analyzer parsing; directive and content-digest caches already exist | Rust substring detection cannot replace Dart semantics; no measured reason to transfer parsing across IPC | High semantic risk; keep existing boundary |
| `graph.rs::dirty_context` | String-keyed BTreeMaps, HashSets and reverse reachability; closure already shared across actions | No changes implies an empty closure: avoid constructing reverse edges entirely | Small, no format changes or CPU assumptions; benchmark independently |
| Dense graph bitsets / POPCNT, LZCNT, TZCNT, BMI | Current graphs use sparse string IDs, not dense bit matrices | Would require ID interning, graph conversion and lifetime management before word-wise operations help | Higher cost; no evidence justifying conversion or an all-pairs reachability matrix; not implemented |
| `digest.rs`, `snapshot.rs`, `validated_digest.rs` | FNV-1a's dependent xor/multiply chain; existing scoped validation reuses eligible AOT file digests | Native compiler comparison; CRC32C/PMULL/PCLMUL change the hash and cannot preserve exact FNV values | No hash replacement: user requires hash semantics/cache compatibility; no simple same-value SIMD transform |
| JSON / `protocol.rs`, workspace and manifest configuration | `serde_json` 1.0.151 with insertion-order preservation; binary graph and binary output/asset payloads already reduce JSON traffic | Dependency source uses `memchr` and SWAR/Mycroft word classification; assess stage timings before replacing parser | No isolated JSON bottleneck demonstrated; `simd-json` would add mutable input/DOM and compatibility costs; not implemented |
| Byte equality, copies, glob scans | Standard slice/string operations, LLVM/libc routines; globs include Dart UTF-16 semantics | Preserve optimized library operations; do not introduce custom SIMD for tiny comparisons or semantics-sensitive glob DP | No measured hotspot requiring replacement |

`memchr` 2.8.3 already exists in the lockfile through `serde_json`. Its default
`std` feature dispatches AVX2 at runtime on capable x86_64, with SSE2 and scalar
fallbacks; aarch64 provides NEON implementations. Standard HashMap/HashSet
already use SwissTable group probing (SIMD where the target implementation
supports it); replacing these with handwritten intrinsics is not justified.

## Technology choices

1. Algorithmic avoidance is the simplest solution to empty reverse closures.
2. Native LLVM optimization is evaluated only as a measurement variant. It
   cannot vectorize away FNV's recurrence or replace scalar lexical searches
   with a portable runtime-dispatched search library automatically.
3. `memchr` provides a maintained safe interface with CPU selection and tails.
   A cached `memmem::Finder` avoids per-candidate searcher construction and
   skips dense runs of individual candidate bytes. An immediate full-keyword
   match bypasses searcher lookup. Both one-byte `memchr` and repeatedly
   constructing `memmem` searches were measured and rejected; see below.
4. `wide` would require implementing search, masks, bounds and tails again.
5. `multiversion` would add variants and dispatch without improving the
   algorithm already supplied by `memchr`.
6. `std::arch` is unnecessary: no measured gap requiring handwritten SIMD.

The production changes add no unsafe code, nightly features, target-specific
flags, persistent formats or scheduler changes. AVX2 is never mandatory.

## Measurement environment

Linux x86_64, Intel Xeon Platinum 8573C under KVM; three visible CPUs, cgroup
quota two CPUs (`200000 100000`), 8 GiB memory limit. Dart 3.13.3, Rust/Cargo
1.98.1. All comparisons use this same host and SDK/cache. Cross-architecture
performance is not inferred from these results.

The mixed fixture uses 500 feature modules, 1,001 input sources and 1,001
generated public files, Freezed 4.0.1, Riverpod generator 4.0.9,
json_serializable 6.14.1, build_runner 2.16.2 and its fixed fixture lockfile.
The worker limit is explicitly two. Clean samples include cold worker AOT
compilation and independent shared caches. Warm samples use the harness's
explicit prewarmed AOT worker. The normal Dart launcher is included.

Exploratory JSON and scanner runs overlapping compilation were excluded from
the final performance comparisons. Sequential whole-build runs showed large
time drift, so warm conclusions use rotated variants in the same workspace.
The first one-byte-search prototype's E2E results are not final-candidate results.
Missing mixed-fixture dependencies were
downloaded with `dart pub get --enforce-lockfile`; tracked lockfiles were not
changed.

## Scanner results

Nanoseconds per call, median of nine batches. `baseline` and `native` use the
old scalar production body; `proposal` is the final shared Finder. The exact
bodies are extracted by `scripts/benchmark_part_scanner.py` and compiled with
`rustc -O`, the pinned toolchain and the release `memchr` rlib. The benchmark
input/loop is shared with the checked-in opt-in Rust test. Compilation completes
before timing. Raw measurement files are generated locally and are not
committed; the tables below summarize the results.

| Input | Baseline ns | Native ns | Proposal ns |
| --- | ---: | ---: | ---: |
| 164 B, absent | 102.0 | 108.2 | 11.4 |
| 4,100 B, absent | 2,407.4 | 2,488.2 | 127.7 |
| 65,559 B, absent | 38,966.3 | 42,959.1 | 2,068.3 |
| 65,550 B, identifiers | 45,211.4 | 47,669.7 | 34,461.1 |
| 65,538 B, dense p | 38,412.0 | 40,705.1 | 2,156.9 |
| 65,578 B, dense p then directive | 38,172.6 | 38,502.2 | 2,148.9 |
| 185 B, immediate directive | 32.0 | 23.8 | 29.1 |
| 695 B, mixed model | 202.7 | 219.9 | 77.3 |
| 137 B, provider | 70.5 | 71.3 | 39.3 |
| 396 B, JSON model | 68.7 | 60.4 | 40.2 |

The real fixtures improve about 42–62%. The 64 KiB absent and dense-byte cases
improve about 18–19x. An immediate keyword needs no searcher lookup; tiny
absolute differences there are not presented as a speedup guarantee. Native
LLVM optimization alone does not solve the scalar byte-search loop.

### Dense candidates: plausibility and rejected approaches

The initial one-byte `memchr(b'p', ...)` prototype improved the tracked sources
but slowed a 64 KiB run of `p` from 38.0 to 64.3 microseconds: every byte was
returned as a candidate, and the extra per-candidate guard cost more than the
old four-byte comparison. This prototype was **not retained**.

We inspected 13,155 Dart files at least 128 bytes long in fixtures, installed
packages and SDK libraries (the collection totals about 162 MB). None contained
four consecutive lowercase `p` bytes. The highest whole-file `p` density was
6.96%. This is evidence about the inspected corpus, not proof that the
input cannot occur. A long
identifier, string literal or generated embedded payload can contain it legally.

A full density prescan would add a pass and initialization cost to ordinary
small files, and a prefix-only check could miss a dense region later in a file.
Instead, the final implementation searches for the complete keyword with a
library-maintained SIMD prefilter: it rejects the dense run during search,
before the parser sees individual candidates. It handles dense regions anywhere,
including a later real directive, without a hand-tuned density threshold.

Creating a Finder for every call removed the dense-byte regression but added
setup cost to small inputs. `OnceLock` now initializes a borrowed, fixed-needle
Finder once per process; subsequent calls reuse it safely across threads.
Repeatedly calling one-shot `memmem::find` was also inferior when `part` occurs
inside identifiers because it repeatedly constructs search state. The
reproduction script includes this rejected strategy for comparison. The
selected Finder preserves the parser's original boundary/trivia/URI checks.

## Dependency graph results

Microseconds per call, median of 14 batches: one pass in baseline/native/proposal
order, another in reverse order. Each pass has seven batches. All context
construction and destruction is timed; input construction is not.

| Nodes / case | Baseline us | Native us | Proposal us |
| --- | ---: | ---: | ---: |
| 64 / no-op | 10.15 | 10.81 | 3.25 |
| 4,096 / no-op | 2,430.61 | 2,065.16 | 767.15 |
| 32,768 / no-op | 22,055.86 | 22,893.88 | 6,861.73 |
| 64 / one-file | 10.26 | 10.80 | 11.06 |
| 32,768 / one-file | 22,560.84 | 22,327.50 | 19,093.34 |
| 32,768 / broad | 29,820.87 | 29,499.41 | 25,843.58 |

No-op context construction improves about 3x and eliminates reverse-edge
allocation. Nonempty change sets still use the original reverse traversal and
maps; no changed-case speedup is claimed. Their medians vary with run order,
including +0.8 us in the small one-file case. The absolute branch cost and code
layout can affect tiny cases; the mixed-build measurements below are needed to
assess practical regressions rather than extrapolating a synthetic percentage.

## End-to-end results

The final warm comparison rotates baseline/native/proposal execution order on
one prepared 500-feature workspace. All variants use the same explicit AOT
worker and cache, two workers, normal Dart launcher, and identical restored
inputs before each edit. No-op has nine samples per variant; other cases have
three. The [follow-up harness](paired_warm.py) delegates CPU/RSS measurement to
`measure_process.py`, checks output inventories and bytes after every sample,
and requires 0/1/500 changed output files for no-op/one-file/broad.

Wall seconds: median (min–max).

| Case | Baseline | Native | Proposal |
| --- | ---: | ---: | ---: |
| no-op | 0.285 (0.277–0.300) | 0.282 (0.278–0.295) | 0.283 (0.273–0.290) |
| one-file | 0.568 (0.563–0.571) | 0.566 (0.556–0.585) | 0.572 (0.568–0.602) |
| broad | 7.823 (7.045–8.198) | 7.256 (7.175–8.677) | 7.478 (7.117–8.262) |

Median aggregate process CPU milliseconds and reported peak RSS KiB:

| Case / variant | CPU ms (user + system) | Peak RSS KiB |
| --- | ---: | ---: |
| no-op / baseline | 323.3 | 59,904 |
| no-op / native | 318.9 | 59,904 |
| no-op / proposal | 320.5 | 59,904 |
| one-file / baseline | 617.1 | 87,352 |
| one-file / native | 613.0 | 87,456 |
| one-file / proposal | 618.5 | 87,352 |
| broad / baseline | 14,946.9 | 202,160 |
| broad / native | 13,844.5 | 201,236 |
| broad / proposal | 14,252.2 | 205,968 |

Final cold Clean controls use independent workspaces and shared caches, with
worker AOT compilation included. These are **one sample per variant**, not
statistically established speedups.

| Variant | Wall s | CPU ms | Peak RSS KiB |
| --- | ---: | ---: | ---: |
| baseline | 44.980 | 66,193.6 | 673,852 |
| native | 45.647 | 64,918.8 | 681,848 |
| proposal | 40.001 | 56,853.1 | 678,288 |

All final Clean variants produced the same 1,001 output files and output hash.
All 45 warm measurements were byte-identical across variants for their case.
This is main-versus-candidate equivalence, not a new stock-build performance claim.

The initial baseline, measured before candidate comparisons, had three Clean
samples spanning 39.660–70.359 s. Its warm no-op median was 0.652 s, whereas
later main controls were around 0.285 s without the proposed code. Comparing
these initial results directly with later proposal samples would greatly
overstate this change.
Only the rotated warm comparison is used for warm conclusions.

**There is no established substantial build-wide speedup.** No-op median changes
by about -1%, one-file by +0.8%, and broad measurements overlap considerably.
CPU and RSS do not show a consistent build-wide reduction. A single diagnostic
no-op trace put dirty checking at 24.1 ms for main and 22.0 ms for the proposal,
but snapshotting moved from 54.5 to 71.6 ms; these untimed diagnostics are not
elapsed-time evidence. Launcher/snapshotting, worker startup,
Analyzer and builders dominate this workload, while the scanner savings are
nanoseconds per small source. The retained changes are small, measured CPU and
allocation improvements to kernels, not a claim of faster AOT compilation or
material application speedups. Validate production Flutter workloads separately.

## Reproduction

```sh
export CARGO_HOME="$PWD/.toolchains/cargo"
export RUSTUP_HOME="$PWD/.toolchains/rustup"
CARGO_BIN="$CARGO_HOME/bin/cargo"
"$CARGO_BIN" build --locked --release --manifest-path rust/Cargo.toml
"$CARGO_BIN" test --locked --release --manifest-path rust/Cargo.toml \
  part_scanner_benchmark -- --ignored --nocapture
"$CARGO_BIN" test --locked --release --manifest-path rust/Cargo.toml \
  dirty_context_benchmark -- --ignored --nocapture

LANE=accelerator WORKLOAD=application COUNT=500 REPEATS=3 ACCELERATOR_JOBS=2 \
  BUILD_RUNNER_ACCELERATOR_BIN=/absolute/path/to/variant \
  RESULTS_DIR=/absolute/path/to/new-results \
  bash scripts/benchmark_current_baseline.sh
```

Build the baseline and candidate into separate output directories, preserve
their executables, and run timing without concurrent compilations or tests.
For an evaluation-only native variant use `RUSTFLAGS='-C target-cpu=native'`
and a separate Cargo target directory. Do not apply this to distribution.
The opt-in microbenchmarks use `black_box`, build inputs outside timing and
include destruction of each dirty context. Scanner output is nanoseconds per
call (nine batches); graph output is microseconds per call (seven batches).
For exact standalone scanner reproduction after the release build:

```sh
python3 scripts/benchmark_part_scanner.py --baseline 617bb0b \
  --rustc "$CARGO_HOME/bin/rustc" \
  --memchr-rlib "$(ls -t rust/target/release/deps/libmemchr-*.rlib | head -1)" \
  --results /tmp/new-scanner-results
```

The paired follow-up used a temporary copy of the existing E2E harness that
retained its disposable workspace on success; [the exact harness delta](retained-harness.patch)
changes only script location resolution and cleanup, not measured commands.
Then run `paired_warm.py --help` and provide that workspace, its shared cache,
the checkout, SDK/pub-cache paths and the three saved executables. The script
restores the generated fixture before each edit; use only the disposable
500-feature benchmark, not an application checkout.

The scanner includes three tracked Dart sources in addition to synthetic sizes
and dense identifier candidates. Graph sizes are 64, 4,096 and 32,768 nodes,
with shared imports and local dependency chains; this is a synthetic topology,
not a substitute for the E2E fixture.

## Allocation diagnostics

A separate, untimed `LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libmemusage.so` run
of the graph benchmark measured the complete invocation, including fixture
setup, all sizes, all three cases, test-harness allocations and context drops.
These are cumulative requested bytes and calls, **not per-build peak RSS**.

| Metric | Baseline | Proposal |
| --- | ---: | ---: |
| malloc calls | 20,172,402 | 13,633,702 |
| realloc calls | 100,966 | 69,746 |
| Total requested heap bytes | 3,160,516,366 | 2,275,872,502 |
| Peak live heap bytes | 25,816,882 | 25,816,882 |

The no-op fast path eliminates reverse-edge vectors and BTreeMap nodes;
one-file and broad cases still build the same closure. The benchmark's peak
is therefore unchanged. Scanner calls use borrowed slices and introduce no
heap allocation; benchmark-owned input construction is outside scanner timing.
A separate scanner allocation probe measured exactly the same 57 malloc calls,
38 realloc calls and 774,225 cumulative requested bytes for both complete
benchmark invocations, including setup, initialization and all scanner calls.
Do not interpret these aggregate allocation totals as application memory savings.

## Correctness and portability checks

- Stable release build, formatting and all-target/all-feature Clippy passed.
- The existing Rust suite passed (229 tests, three ignored), including new
  empty-closure/cycle, digest/presence/add/remove, Unicode scanner offset,
  short-tail and dense-candidate coverage.
- An exploratory differential probe compared the old and new production
  scanner bodies on 100,000 deterministic UTF-8 inputs containing comments,
  quotes, escapes, identifier fragments and Unicode: all decisions matched.
- Release `cargo check --locked` passed for Linux x86_64 and aarch64, macOS
  aarch64, Windows x86_64 and aarch64. Cross-checking does not execute or link
  binaries on those other operating systems; existing native CI remains needed.
- Disassembly of the ordinary release binary includes runtime-selected
  `memchr::arch::x86_64::avx2::packedpair::Finder` routines with `vpcmpeqb` and
  `vpmovmskb`.
  Their presence does not make AVX2 mandatory, nor prove an E2E
  speedup. No handwritten intrinsic or unsafe block was added.

The existing long integration verification was interrupted at the user's request
and deferred to CI. Earlier smoke and manifest-cache probes completed, but they
are not claimed as a full final-version integration gate. The final Rust checks,
differential scanner probe, cross-target checks and measured output comparisons
above completed. Full watch/stock compatibility suites and execution on other
CPU/OS combinations remain CI/reviewer follow-up.
