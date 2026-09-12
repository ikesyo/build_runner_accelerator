# Benchmarks

This document records the latest launcher-inclusive comparison for the public
preview. It measures the stock Dart `build_runner` command against the
project-facing accelerator launcher using the same fixture and dependency
resolution.

## Latest run

- Workflow: [Current baseline benchmark](../.github/workflows/benchmark-current.yml)
- Run: [GitHub Actions run #1](https://github.com/ikesyo/build_runner_accelerator/actions/runs/34686980508)
- Application commit: `c14bbfda9110e0aa9d7fae3042990440ab8c796f`
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
| clean | 41,606 | 31,439 | 30,465 | 34,840 | 1.32x / 1.37x / 1.19x |
| no-op | 1,014 | 410 | 393 | 447 | 2.47x / 2.58x / 2.27x |
| one-file | 1,050 | 521 | 478 | 553 | 2.01x / 2.20x / 1.90x |
| broad | 1,057 | 514 | 493 | 543 | 2.06x / 2.15x / 1.95x |

The full five-repeat ranges were:

| Case | Stock range | Accelerator jobs=1 | Accelerator jobs=2 | Accelerator jobs=4 |
| --- | ---: | ---: | ---: | ---: |
| clean | 40,716–42,698 | 30,921–31,965 | 29,419–31,439 | 33,536–36,548 |
| no-op | 987–1,047 | 395–429 | 380–413 | 420–482 |
| one-file | 1,020–1,093 | 505–541 | 461–502 | 526–581 |
| broad | 1,026–1,089 | 501–536 | 475–510 | 518–570 |

## Runtime resources

User/system are child CPU milliseconds and RSS is peak KiB.

| Lane | Case | User ms | Sys ms | Peak RSS KiB |
| --- | --- | ---: | ---: | ---: |
| stock default | clean | 49,093 | 2,343 | 694,648 |
| stock default | no-op | 1,024 | 262 | 161,880 |
| stock default | one-file | 1,060 | 251 | 161,940 |
| stock default | broad | 1,065 | 256 | 161,972 |
| accelerator jobs=1 | clean | 35,907 | 2,748 | 634,032 |
| accelerator jobs=1 | no-op | 626 | 157 | 266,604 |
| accelerator jobs=1 | one-file | 737 | 210 | 267,188 |
| accelerator jobs=1 | broad | 739 | 201 | 267,052 |
| accelerator jobs=2 | clean | 38,332 | 2,238 | 647,596 |
| accelerator jobs=2 | no-op | 646 | 122 | 266,540 |
| accelerator jobs=2 | one-file | 795 | 178 | 267,436 |
| accelerator jobs=2 | broad | 811 | 180 | 267,060 |
| accelerator jobs=4 | clean | 45,698 | 2,988 | 652,796 |
| accelerator jobs=4 | no-op | 690 | 161 | 266,036 |
| accelerator jobs=4 | one-file | 965 | 246 | 266,408 |
| accelerator jobs=4 | broad | 962 | 246 | 266,152 |

## Watch smoke

The paired stock/Rust watch run took 44.47 seconds and passed:

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
- The accelerator improved clean builds by 1.19–1.37x and warm builds by
  1.90–2.58x, including the project-facing launcher.
- Incremental accelerator runs used roughly 266–267 MiB peak RSS versus
  roughly 162 MiB for stock. Clean runs used less peak RSS than stock, but
  still had substantially higher fixed initialization cost than warm runs.

## Scope and limitations

This is one GitHub Actions Ubuntu x64 environment and one small extracted
fixture, not a cross-platform or broad open-source compatibility claim. The
stock path does not expose the old `--jobs` flag, so the jobs matrix applies
only to the accelerator lane.

Release artifact download, cache-miss installation, and cross-platform native
builds are not included. Historical kernel/AOT/direct-worker experiments and
earlier spot checks are retained in
[`experiments-2026-09.md`](benchmarks/experiments-2026-09.md).
