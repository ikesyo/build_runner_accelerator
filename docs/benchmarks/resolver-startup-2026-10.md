# Resolver optimizations: local 0.8.0 comparison (2026-10-02)

The baseline is tag `0.8.0`, commit
`4590fde5527c8bb0d15976b43baabc5b4968cffc`. The candidate is
`2db687ca16f81cacfcaaa8b403720a1c20b56f93`: the six supplied resolver
optimization commits, preserved unchanged, plus four review fixes.

## Conditions

- Linux x64, AMD EPYC 9V74, three available CPUs; native release binaries built
  separately with Rust/Cargo 1.98.1 and `--locked`.
- Dart 3.13.3, worker AOT enabled, `--jobs 1`, runtime metrics enabled in both
  revisions. No other verification suites ran during the comparison.
- The same SDK and pub cache are shared. Each revision has its own accelerator
  and analyzer caches; both are primed before measurements. Worker compilation,
  dependency resolution, stock reference builds and warmup are excluded.
- JSON uses analyzer 14.4.0; Freezed and Riverpod use analyzer 14.3.0.
  All use build_runner 2.16.1 and json_serializable 6.14.1. Freezed is 4.0.1;
  riverpod_generator is 4.0.9. Stock, baseline and candidate package
  configurations have identical dependency entries within each fixture.
- Five samples per revision and case, alternating revision order each round:
  baseline/candidate, candidate/baseline, baseline/candidate,
  candidate/baseline, baseline/candidate.
- `clean` removes source outputs, the native graph, generated cache and overlay,
  while preserving manifest, worker AOT and analyzer caches. It is a warm clean
  build, not a first-ever build. `noop` follows it without edits. `one-file`
  appends a comment to the first source input; `broad` changes all source inputs.
- Each of the 120 measured builds compares source outputs and cached `.g.part`
  files byte-for-byte with stock build_runner. All comparisons passed. No measured
  build recompiled worker AOT; every no-op used the native no-work path.
- Wall time measures the native process, excluding the Dart launcher. Process
  waits block directly: Python's timed wait polling would round these short
  measurements by up to 50 ms. A separate watchdog bounds each process to ten
  minutes.

## Results

Milliseconds: median (minimum–maximum), five samples. The change is candidate
divided by baseline minus one; negative values mean less time.

| Fixture | Case | 0.8.0 | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| JSON, 10 inputs | clean | 260.996 (246.830–265.225) | 248.688 (240.542–259.220) | -4.7% |
| JSON, 10 inputs | noop | 3.615 (2.878–4.860) | 3.644 (2.944–5.291) | +0.8% |
| JSON, 10 inputs | one-file | 229.089 (227.080–251.311) | 221.860 (219.582–234.085) | -3.2% |
| JSON, 10 inputs | broad | 253.452 (248.714–264.624) | 251.939 (242.886–253.896) | -0.6% |
| Freezed | clean | 304.710 (294.951–353.949) | 282.140 (270.375–287.460) | -7.4% |
| Freezed | noop | 3.332 (3.099–3.917) | 3.516 (3.397–3.582) | +5.5% |
| Freezed | one-file | 281.572 (279.025–341.622) | 266.852 (250.859–276.881) | -5.2% |
| Freezed | broad | 314.928 (299.093–336.228) | 279.793 (267.439–290.130) | -11.2% |
| Riverpod | clean | 585.544 (547.137–603.188) | 425.849 (407.574–450.475) | -27.3% |
| Riverpod | noop | 7.837 (7.703–8.336) | 8.442 (7.655–9.331) | +7.7% |
| Riverpod | one-file | 588.376 (550.893–611.550) | 442.314 (417.518–454.574) | -24.8% |
| Riverpod | broad | 577.672 (563.441–626.645) | 431.207 (426.647–449.065) | -25.4% |

Riverpod shows the clearest reduction, with non-overlapping observed ranges
for the three build cases. Freezed also improves. JSON differences are small
and its observed ranges overlap. No-op medians increase by 0.029 ms, 0.184 ms
and 0.606 ms respectively; five samples do not establish a stable regression
at this scale.

The common `Dart metrics` instrumentation supports the Riverpod result. On
clean builds, the first `riverpod_generator:riverpod_generator` action for
`lib/model.dart` falls from a median 478.524 ms to 316.645 ms (-33.8%);
`run_builder_us` falls from 386.647 ms to 231.803 ms. Initial resolver acquisition
stays around 123–127 ms. These are action measurements, not additional wall-time
samples.

This comparison measures the complete PR against 0.8.0. The supplied report's
approximately 30% first-`libraryFor` and 12% action reductions describe the final
packed-store step on Dart 3.13.5, so those percentages are not directly
comparable. This run does not measure cold compilation, cold OS caches,
multi-worker scaling or the public Dart launcher.

## Reproduction

Use a detached baseline worktree and **separate Cargo target directories** for
the two revisions; sharing a target directory can reuse the other worktree's
binary. Resolve the candidate's three fixture dependencies with the chosen
Dart SDK first. Pass the same SDK and pub cache throughout.

```bash
git worktree add --detach /path/to/baseline 4590fde5527c8bb0d15976b43baabc5b4968cffc
CARGO_TARGET_DIR=/path/to/target-baseline \
  cargo build --release --locked --manifest-path /path/to/baseline/rust/Cargo.toml
CARGO_TARGET_DIR=/path/to/target-candidate \
  cargo build --release --locked --manifest-path rust/Cargo.toml

PUB_CACHE=/path/to/pub-cache python3 scripts/benchmark_resolver_comparison.py \
  --baseline-root /path/to/baseline \
  --baseline-bin /path/to/target-baseline/release/build_runner_accelerator \
  --candidate-root "$PWD" \
  --candidate-bin /path/to/target-candidate/release/build_runner_accelerator \
  --dart /path/to/dart-sdk/bin/dart \
  --results /path/to/fresh-results --jobs 1 --repeats 5
```

The script keeps stock references, workspaces, caches, raw logs, per-action
metrics, all sample wall times, binary hashes and revision metadata in the
result directory. `--reuse-workspaces` can repeat samples after a completed
preparation run with the same revisions and dependencies. The local final run
used `/workspace/resolver-ab-results/comparison` with this option after correcting
timed process waits. The final invocation log is
`/workspace/resolver-ab-results/comparison-precise.log`; environment snapshots
are `/workspace/resolver-ab-results/environment-{before,after}.json`.

Local release binary SHA-256 values:

- Baseline: `95378091422ab9b679cb68cdb02f2382b5790def20fc5bb83761b2eb095ba169`
- Candidate: `c527ddebedae4dd702415379e3bac9bcf1174aa05ba6674fa06d811313a449c0`
