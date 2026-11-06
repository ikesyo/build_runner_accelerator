# Current-main performance comparison

The proposed portable Release reduces median No-op time by **7.8%** and
One-file time by **7.9%** against current main in the 500-feature mixed app.
Clean has no demonstrated improvement. Broad's median is **7.2% slower**;
its high variability leaves a possible regression unresolved.

## Conditions

- Main: `5ae9ee8f18b305104e3e2b26dd61a22d7afb408a`.
- Proposal: `e064e57874306b0afba5a22f10b626c0e5223ecb`.
- Linux x86_64 KVM, Xeon Platinum 8573C, three visible CPUs, two-CPU cgroup
  quota (`200000 100000`), 8 GiB memory limit; 2026-11-06.
- Stable Rust 1.98.1, Dart 3.13.3, two workers, launcher included.
- Locked 500-feature application: Freezed 4.0.1, Riverpod generator 4.0.9,
  json_serializable 6.14.1 and build_runner 2.16.2; 1,001 generated files.
- Normal main Release, main with evaluation-only `-C target-cpu=native`,
  and normal proposal Release. All three binaries finish compiling before E2E.
  Metrics, wall traces and analysis traces are disabled during timing.
- Each group uses all six permutations of the three variants. No-op repeats
  those permutations five times, One-file twice, Clean/Broad once.
  No other compilation, benchmarks or verification run alongside timing.
- Clean uses an independent workspace and empty shared cache per sample and
  includes normal launcher AOT compilation. Dependencies are resolved offline
  with the fixture lockfile before timing. This is a cold application/cache
  build, not a flushed OS page-cache experiment.
- Warm cases use one immutable AOT executable copied from main's final Clean.
  Its SHA-256 is checked after every sample. Graph and manifest snapshots are
  saved/restored per variant. Edited samples restore base inputs and rebuild
  outside timing before applying the measured edit.

Both measured revisions contain #163's Finder reuse and empty-change shortcut.
FVM pruning, resolver-aware scheduling, digest reuse and directive parse caching
are retained. These samples are independent of the initial investigation's
older measured commits; the campaigns are not pooled.

## E2E results

Wall seconds, median (minimum–maximum):

| Case / samples per variant | Main Release | Native main | Proposal Release |
| --- | ---: | ---: | ---: |
| Clean / 6 | 45.571 (44.071–46.050) | 44.780 (43.945–45.440) | 45.794 (44.208–46.995) |
| No-op / 30 | 0.313 (0.296–0.330) | 0.314 (0.299–0.352) | 0.288 (0.276–0.343) |
| One-file / 12 | 0.607 (0.590–0.626) | 0.610 (0.593–0.649) | 0.559 (0.547–0.586) |
| Broad / 6 | 8.987 (8.331–15.198) | 9.630 (8.754–10.397) | 9.637 (7.917–15.565) |

Percentage changes compare the unrounded medians. Proposal is faster than main
in 28/30 matched No-op rounds and 12/12 One-file rounds. Median paired wall
changes are −21.9 ms and −45.0 ms respectively. The One-file ranges do not overlap;
No-op has two slower proposal samples. These establish improvements for these
cases on this workload, not every project or platform.

Clean's proposal median is 0.5% slower, with 3/6 paired wins and overlapping
ranges. Broad has only 2/6 paired wins; its median paired change is +315 ms
(range −1,178 to +3,257 ms). Broad is not evidence of an improvement, and a
regression cannot be excluded. Its slow samples also consume more CPU: main's
15.198 s sample uses 29.467 CPU seconds, versus 17.488 CPU seconds for its
9.053 s sample. Waiting alone does not explain the variation. Phase-level
attribution and more workloads are needed to identify its cause; the kernel
improvement below does not resolve it.

Median resource observations:

| Case | CPU seconds main / native / proposal | Max child RSS MiB main / native / proposal |
| --- | ---: | ---: |
| Clean | 65.593 / 63.925 / 65.865 | 663.22 / 662.89 / 661.53 |
| No-op | 0.356 / 0.358 / 0.330 | 58.50 / 58.50 / 58.50 |
| One-file | 0.654 / 0.660 / 0.608 | 84.87 / 84.88 / 84.86 |
| Broad | 17.355 / 18.622 / 18.632 | 199.10 / 194.99 / 193.67 |

CPU time is user plus system time. RSS is `measure_process.py`'s child-process
high-water mark, not simultaneous aggregate process-tree memory or Rust heap.
No whole-build memory reduction is established. Native main does not improve
warm No-op/One-file; no distribution CPU requirements change.

All **162 E2E samples** succeeded and matched main's generated file sets/bytes.
No-op changes zero outputs, One-file changes one, and Broad changes 500 of the
1,001 outputs. This campaign compares against main; the initial report's separate
stock equality check is not counted as a new stock run.

## Cache invalidation and ordinary launcher

Three old-hash preparations use the ordinary launcher without an
explicit worker override. Each preparation selects a separate shared cache.
Baseline preparation is outside timing. After an ordinary baseline No-op,
proposal rebuilds obsolete state, followed by an ordinary proposal No-op.

| Case / 3 samples | Median seconds (minimum–maximum) |
| --- | ---: |
| Main steady No-op | 0.321 (0.304–0.327) |
| Proposal hash upgrade | 40.388 (39.170–43.518) |
| Proposal immediately following No-op | 0.290 (0.284–0.354) |

Every upgrade logs schema 7 invalidation and AOT recompilation. All nine measured
runs preserve the 1,001 generated files and their bytes. The upgrade cost is
separate from steady timings. Three following No-ops with overlapping ranges
are a correctness/cost control, not another independent speedup claim.

## Current dirty-context kernel

Exact function bodies from the two measured revisions, identical snapshots and
edges, seven batches per row, then a second pass reversing variant order.
Tables report the median of the two pass medians. Separate untimed calls count
allocator requests and peak live requested heap. Setup inputs are excluded;
returned context construction/destruction is included. Every case checks its
changed/tainted sets against main. Fixed 16-character digest strings isolate the
snapshot algorithm; production's longer BLAKE3 strings are included in E2E.

Microseconds:

| Entries / case | Main | Native main | Proposal | Allocations / peak heap bytes, all variants |
| --- | ---: | ---: | ---: | --- |
| 64 / No-op | 3.42 | 3.46 | 0.59 | 0 / 0 |
| 4,096 / No-op | 795.06 | 818.17 | 53.46 | 0 / 0 |
| 32,768 / No-op | 7,490.39 | 7,335.55 | 694.99 | 0 / 0 |
| 64 / last-entry change | 10.78 | 10.07 | 7.34 | 81 / 9,944 |
| 4,096 / last-entry change | 2,057.68 | 2,003.04 | 1,242.54 | 4,790 / 647,600 |
| 32,768 / last-entry change | 19,753.74 | 18,776.32 | 11,849.48 | 38,244 / 5,186,152 |
| 32,768 / shared dependency | 27,834.21 | 25,950.89 | 19,683.72 | 38,259 / 7,381,492 |
| 32,768 / disjoint snapshots | 45,124.27 | 42,765.78 | 40,326.26 | 38,274 / 11,805,104 |

Both No-op implementations skip reverse-graph construction. Ordered merge still
avoids main's repeated tree lookups. Allocations and peak requested heap remain
equal. All 12 size/case combinations improve in this kernel; synthetic graph
percentages must not be extrapolated to E2E. Hash/JSON/representation candidates
are unchanged; their initial kernel measurements were not rerun in this campaign.

## Reproduction

The [E2E and upgrade harnesses](https://github.com/ikesyo/build_runner_accelerator/tree/f9c1bce9b2e71334b129a5fb51a1eaa961a2edf2/scripts/perf-kernels)
are an evaluation snapshot. Use a fresh output directory and the pinned toolchain:

```sh
repo="$PWD"
out=/tmp/bra-current-main-evaluation
export CARGO_HOME="$repo/.toolchains/cargo"
export RUSTUP_HOME="$repo/.toolchains/rustup"
cargo="$CARGO_HOME/bin/cargo"
mkdir -p "$out/main" "$out/proposal" "$out/eval"
git archive 5ae9ee8 rust | tar -x -C "$out/main"
git archive e064e57 rust | tar -x -C "$out/proposal"
git archive 37c0194 scripts/perf-kernels | tar -x -C "$out/eval"
for script in remeasure_e2e remeasure_upgrade; do
  git show "f9c1bce:scripts/perf-kernels/$script.py" > "$out/$script.py"
done
"$cargo" build --locked --offline --release --manifest-path "$out/main/rust/Cargo.toml"
cp "$out/main/rust/target/release/build_runner_accelerator" "$out/baseline"
RUSTFLAGS='-C target-cpu=native' CARGO_TARGET_DIR="$out/native-target" \
  "$cargo" build --locked --offline --release --manifest-path "$out/main/rust/Cargo.toml"
cp "$out/native-target/release/build_runner_accelerator" "$out/native"
"$cargo" build --locked --offline --release --manifest-path "$out/proposal/rust/Cargo.toml"
cp "$out/proposal/rust/target/release/build_runner_accelerator" "$out/proposed"
python3 "$out/remeasure_e2e.py" --repository "$repo" --results "$out"
python3 "$out/remeasure_upgrade.py" --repository "$repo" --results "$out"
```

For the context kernel, use `compare_context.py` from `37c0194`, setting its
`repo` variable to this checkout's absolute path. Run it with
`--baseline 5ae9ee8 --results "$out/context" --rustc "$CARGO_HOME/bin/rustc"`.
After all three compilations finish, execute the resulting binaries in the order
`baseline native proposal proposal native baseline`. Run this separately from E2E.
