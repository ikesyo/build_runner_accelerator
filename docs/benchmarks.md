# Benchmarks

This document records the latest launcher-inclusive comparison for the public
preview. It measures the stock Dart `build_runner` command against the
project-facing accelerator launcher using the same fixture and dependency
resolution.

## Latest run

- Workflow: [Current baseline benchmark](../.github/workflows/benchmark-current.yml)
- Run: [GitHub Actions run #5](https://github.com/ikesyo/build_runner_accelerator/actions/runs/34726219732)
- Application commit: `399f92e7dc14fe94e33c357bdca4e5655b7c2850`
- Environment: GitHub Actions `ubuntu-24.04`, Linux x64
- Dart SDK: 3.13.3
- Rust: 1.98.1
- `build_runner`: 2.16.1
- `json_serializable`: 6.14.1
- `json_annotation`: 4.12.0
- Fixture: `fixtures/current_json_app`, 10 independent inputs
- Native binary: optimized Rust release build
- Accelerator mode: project-facing Dart launcher with `--mode rust`
- Repeats: 5 independent repeats per case

The run measured the four baseline cases with the stock lane and the
accelerator at `jobs=1/2/4`. It also ran the paired current-JSON watch smoke
test. Raw JSONL, stdout/stderr, and watch logs are retained in the workflow
artifacts.

## Method

The benchmark stages an isolated package copy for every case. Stock uses the
default `dart run build_runner build` path. The accelerator uses the normal
Dart launcher with a prebuilt release frontend and `ACCELERATOR_LAUNCHER=1`.
The accelerator worker count is varied with `--jobs 1/2/4`.

- `clean` measures the first build without a warm-up.
- `no-op`, `one-file`, and `broad` perform an unmeasured warm-up in the
  same staged package before the measured build.
- `one-file` changes one input marker; `broad` changes all ten markers.
- Dependency resolution uses the tracked lockfile and the current package
  versions above.
- `scripts/measure_process.py` records wall time, child user/system CPU time,
  peak RSS, exit status, and generated-output hashes.

## Results

Times are milliseconds. Each cell is the median of five repeats; the
parenthesized values are the minimum and maximum.

| Case | Stock | Accelerator jobs=1 | Accelerator jobs=2 | Accelerator jobs=4 | Speedup 1/2/4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| clean | 40,205 | 29,716 | 25,513 | 34,881 | 1.35x / 1.58x / 1.15x |
| no-op | 990 | 395 | 321 | 467 | 2.51x / 3.08x / 2.12x |
| one-file | 1,022 | 497 | 411 | 564 | 2.06x / 2.49x / 1.81x |
| broad | 1,025 | 488 | 412 | 567 | 2.10x / 2.49x / 1.81x |

The full five-repeat ranges were:

| Case | Stock range | Accelerator jobs=1 | Accelerator jobs=2 | Accelerator jobs=4 |
| --- | ---: | ---: | ---: | ---: |
| clean | 40,048–40,462 | 28,779–30,558 | 25,039–25,868 | 34,528–35,253 |
| no-op | 983–1,003 | 371–451 | 319–331 | 434–488 |
| one-file | 1,011–1,037 | 475–506 | 406–418 | 556–579 |
| broad | 1,015–1,037 | 472–507 | 410–429 | 551–576 |

## Runtime resources

The table reports median child CPU milliseconds and median peak RSS in KiB.

| Lane | Case | User ms | Sys ms | Peak RSS KiB |
| --- | --- | ---: | ---: | ---: |
| stock default | clean | 47,343 | 2,271 | 693,652 |
| stock default | no-op | 994 | 249 | 164,368 |
| stock default | one-file | 1,042 | 252 | 161,900 |
| stock default | broad | 1,027 | 256 | 161,768 |
| accelerator jobs=1 | clean | 35,211 | 2,012 | 653,176 |
| accelerator jobs=1 | no-op | 630 | 132 | 266,348 |
| accelerator jobs=1 | one-file | 757 | 168 | 267,272 |
| accelerator jobs=1 | broad | 747 | 173 | 267,008 |
| accelerator jobs=2 | clean | 31,051 | 2,347 | 658,080 |
| accelerator jobs=2 | no-op | 484 | 128 | 268,460 |
| accelerator jobs=2 | one-file | 632 | 189 | 267,524 |
| accelerator jobs=2 | broad | 640 | 177 | 267,972 |
| accelerator jobs=4 | clean | 46,087 | 3,064 | 651,804 |
| accelerator jobs=4 | no-op | 718 | 155 | 265,972 |
| accelerator jobs=4 | one-file | 995 | 237 | 266,052 |
| accelerator jobs=4 | broad | 976 | 250 | 266,200 |

## Watch smoke

The paired stock/Rust watch run took 44.99 seconds and passed:

- input change
- generated-output deletion and restoration
- source rename
- stock/Rust generated-output equality

This is an end-to-end smoke duration, not a per-lane rebuild latency measurement.

## Correctness

All 80 measured invocations exited successfully, produced ten generated
outputs, and produced the same SHA-256 output hash:

`51d4d65d98a4d9956c10685bb3a690b9106fb96e7a7bd4e96df7c830fe4c8651`

## Interpretation

- `jobs=2` was the best setting for every measured case on this runner.
- `jobs=4` was slower than `jobs=2`, so the higher worker count is not a
  default candidate for this ten-input fixture.
- The accelerator improved clean builds by 1.15–1.58x and warm builds by
  1.81–3.08x, including the project-facing launcher.
- Incremental accelerator runs used roughly 266–268 MiB peak RSS versus
  roughly 162 MiB for stock. Clean runs used 651–658 MiB versus 694 MiB for
  stock, while still completing faster than stock.

## Scope and limitations

This is one GitHub Actions Ubuntu x64 environment and one small extracted
fixture, not a cross-platform or broad open-source compatibility claim. The
stock path does not expose the old `--jobs` flag, so the jobs matrix applies
only to the accelerator lane.

Release artifact download, cache-miss installation, and cross-platform native
builds are not included. Historical kernel/AOT/direct-worker experiments and
earlier spot checks are retained in
[`experiments-2026-09.md`](benchmarks/experiments-2026-09.md).
