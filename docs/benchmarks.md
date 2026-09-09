# Benchmarks

This document records the latest launcher-inclusive comparison for the public
preview. It measures the stock Dart `build_runner` command against the
project-facing accelerator launcher using the same fixture and dependency
resolution.

## Method

- Commit: `e2a6a3d0f5684ebd8a9c6f2140e15373ae6c7d98`
- Environment: Linux x64, AMD EPYC 9V74, 9 vCPUs, no swap
- Dart SDK: 3.13.3
- Rust: 1.88.0
- `build_runner`: 2.16.1
- `json_serializable`: 6.14.1
- `json_annotation`: 4.12.0
- Fixture: `fixtures/current_json_app`, 10 independent inputs
- Native binary: optimized Rust release build
- Worker mode: launcher-default AOT
- Repeats: 5 independent repeats per case
- Order: stock was measured followed by accelerator for each case
- Warm cases: an unmeasured warm-up build preceded each measured change
- Measurement: wall-clock time from `scripts/measure_process.py`

The accelerator lane was invoked through the normal Dart launcher with a
preinstalled release binary. Release artifact download and cache-miss
installation are not included. The clean accelerator measurement includes
workspace-local worker AOT cache generation.

## Results

Times are milliseconds. Each cell is
`median (IQR; min–max)`.

| Case | Stock build_runner | Accelerator launcher | Median speedup |
| --- | ---: | ---: | ---: |
| clean | 36,344 (316; 35,640–37,257) | 29,088 (1,241; 28,066–30,052) | 1.25x |
| no-op | 838 (109; 769–970) | 444 (124; 378–530) | 1.89x |
| one-file change | 926 (51; 891–995) | 472 (34; 453–527) | 1.96x |
| broad change | 820 (44; 772–848) | 456 (83; 426–537) | 1.80x |

## Correctness

All 40 measured invocations produced 10 generated outputs with the same
SHA-256 output hash:

`51d4d65d98a4d9956c10685bb3a690b9106fb96e7a7bd4e96df7c830fe4c8651`

## Scope and limitations

This is one Linux x64 environment and one small extracted fixture, not a
cross-platform or broad open-source compatibility claim. The fixture exercises
`json_serializable`; other builders and complex output mappings require
separate validation.

The warm results include the launcher process and the native frontend, while
the native binary is supplied through `BUILD_RUNNER_ACCELERATOR_BIN`. They do
not include release download time. Historical kernel/AOT/direct-worker
experiments and earlier spot checks are retained in
[`experiments-2026-09.md`](benchmarks/experiments-2026-09.md).
