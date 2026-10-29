# Benchmarks

For native-to-native scheduling comparisons in JIT and AOT modes, see
[workspace and single-package scheduler benchmarks](benchmarks/workspace-scheduler-2026-10/README.md).
The stock-versus-native application comparison below measures a separate workload.

## Mixed application comparison (2026-10-24)

This synthetic benchmark compares stock build_runner with the accelerator
using its normal Dart launcher and default worker count. It uses **500 feature
modules**, with three repeats of four build cases.
Each module has a typed JSON model, a serializable Freezed state union, a Riverpod
provider, and ordinary service code. Modules import shared nested types, an enum
and a configuration provider, exercising multiple generator phases and
shared-type invalidation.

| Layer | Inputs and relationships | Public generated files |
| --- | --- | --- |
| Shared | Address DTO, Lifecycle enum, keep-alive configuration provider | shared.g.dart |
| Each feature's model.dart | 11-field DTO with nested Address/list/map/DateTime/enum/nullability; four-case Freezed union; provider watches shared configuration | model.freezed.dart and combined model.g.dart |
| Each feature's service.dart | Ordinary application code imports its generated model/state APIs; excluded from generate_for | None |

There are **1,001 Dart sources and 1,001 generated outputs**, totaling about
8 MB of generated code. This pure-Dart fixture uses Freezed, json_serializable
and Riverpod. Its uniform modules and single shared dependency layer are simpler
than a production application; the results do not predict other projects or OSes.

- Implementation: 0.16.0, `aecded06cb0cf1ea166c7d6814b742f5e9ab558f`.
  Measured harness/generator snapshot: `c3a0ad9`.
  No execution-engine changes are included.
- Host: Debian 13 Linux x64, AMD EPYC 9V74; 3 visible CPUs, cgroup quota 2 CPUs,
  memory limit 8 GiB. Native uses its default limit of two workers;
  `--jobs` is not specified.
- Dart 3.13.3; Rust/Cargo 1.98.1 release frontend; build_runner 2.16.2,
  Analyzer 14.5.0, build 4.0.10, build_config 1.3.2, source_gen 4.2.4.
- [Fixture lockfile](../fixtures/riverpod_app/pubspec.lock): Freezed 4.0.1,
  freezed_annotation 3.1.0, json_serializable 6.14.1, json_annotation 4.12.0,
  riverpod_generator 4.0.9, riverpod_annotation 4.0.7 and riverpod 3.4.3.
  Both lanes enforce the same lockfile and start from identical generated inputs.

## Results

Wall seconds: median (min–max), three samples per case.

| Case | Stock | Native default | Median speedup |
| --- | ---: | ---: | ---: |
| Clean (AOT-cold) | 49.486 (47.366–49.610) | 40.748 (39.938–40.861) | 1.21x |
| no-op | 1.329 (1.319–1.367) | 0.288 (0.270–0.303) | 4.62x |
| one-file | 1.810 (1.801–1.900) | 0.549 (0.534–0.563) | 3.29x |
| broad | 10.165 (10.025–10.703) | 5.550 (5.372–6.026) | 1.83x |

Median child CPU milliseconds and reported RSS KiB:

| Lane | Case | User ms | System ms | Peak RSS KiB |
| --- | --- | ---: | ---: | ---: |
| stock | clean | 56,851 | 2,319 | 727,156 |
| stock | no-op | 1,372 | 275 | 159,084 |
| stock | one-file | 1,980 | 308 | 165,592 |
| stock | broad | 11,255 | 472 | 332,864 |
| native-default | clean | 52,825 | 3,140 | 674,280 |
| native-default | no-op | 247 | 96 | 59,520 |
| native-default | one-file | 440 | 165 | 87,132 |
| native-default | broad | 9,743 | 628 | 178,892 |

## Reproduce

Run [benchmark_current_baseline.sh](../scripts/benchmark_current_baseline.sh)
from the repository root, or use the existing
[benchmark workflow](../.github/workflows/benchmark-current.yml).

```bash
export DART_BIN=/path/to/dart-sdk/bin/dart
export CARGO_BIN=/path/to/cargo
export PUB_CACHE=/path/to/shared/pub-cache
export WORKLOAD=application COUNT=500 REPEATS=3 PUB_GET_OFFLINE=0 TRACE_MODE=0
"$DART_BIN" --suppress-analytics pub get --enforce-lockfile
"$CARGO_BIN" build --locked --release --manifest-path rust/Cargo.toml
export BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/release/build_runner_accelerator"
LANE=stock RESULTS_DIR=/tmp/bra-stock bash scripts/benchmark_current_baseline.sh
LANE=accelerator RESULTS_DIR=/tmp/bra-native bash scripts/benchmark_current_baseline.sh
for case_name in clean no-op one-file broad; do
  cmp /tmp/bra-stock/expected-output-sha256.$case_name \
      /tmp/bra-native/expected-output-sha256.$case_name || exit 1
done
```

Use new results directories. `COUNT` is the number of feature modules, not the
source/output count; both are `2*COUNT+1`. Temporary workspaces are generated
by [generate_application_fixture.py](../scripts/generate_application_fixture.py).
The recorded run fetched dependencies before measuring and used
`PUB_GET_OFFLINE=1`; the commands above allow fetching missing packages during
unmeasured setup.

Timed commands are `dart --suppress-analytics run build_runner build` and
`dart --suppress-analytics run build_runner_accelerator build`, with the prebuilt
frontend override. The complete native Dart launcher is inside the timer.
`ACCELERATOR_JOBS=default` omits `--jobs`; set `ACCELERATOR_JOBS=N` to investigate
an explicit worker limit. The optional `WORKLOAD=json COUNT=1000` profile uses
independent JSON models and is a different workload.

## Preparation and edits

Clean (AOT-cold) uses a fresh workspace and empty native shared caches for each
sample, including analyzer caches. Launcher/manifest preparation and worker AOT
compilation are timed. Dependency fetching, Rust compilation and native binary
download are excluded. OS page caches are not flushed.

Warm samples reuse the last clean workspace, or prepare one if clean is omitted.
Both lanes complete an unmeasured baseline build; native uses a prewarmed AOT
worker. Before each edited sample, restore input sources and build the baseline
outside timing.

| Case | Timed input change | Changed generated outputs |
| --- | --- | ---: |
| Clean (AOT-cold) | Initial generation | All 1,001 are created |
| no-op | None | 0 |
| one-file | Rename one DTO's JSON key in one feature model | 1 model.g.dart |
| broad | Add an enum member in shared.dart only; all feature serializers depend on it | 500 model.g.dart files |

## Measurement notes

The harness requires successful builds and matching generated-file sets and
contents across stock/native and repeats. Output checks run outside timing.

Wall times are medians and min–max of three samples, not confidence intervals.
Stock ran first; execution order and host scheduling may affect the results.
Diagnostics and traces were disabled. All native samples used AOT workers.

[measure_process.py](../scripts/measure_process.py) records elapsed wall time,
child user/system CPU time, and child high-water RSS (KiB on Linux). RSS is not
the sum of simultaneously resident processes; coverage depends on child reaping.
Prewarm, baseline restoration and output checks are outside warm timings.
Raw records and logs are retained locally or in the workflow's 14-day artifacts;
bulk measurement logs are not committed.

## Real-project examples: 0.16.0

These user-reported measurements cover **the same private Flutter application
on two Linux hosts**, separate from the synthetic fixture above. They were not
independently replayed here. SDKs, dependencies and cache conditions differ;
compare stock/native within each host, not absolute times across hosts.

### Build states

The native binary is already downloaded in all comparisons below. Dependency
fetching and diagnostic settings were not specified.

| State | Stock | Native |
| --- | --- | --- |
| Clean (AOT-cold) | Remove build caches and asset graph | Remove workspace state and user caches, including compiled worker and analyzer caches |
| Rebuild (analyzer caches retained) | Same stock-clean reference | Remove workspace state and compiled worker; retain analyzer caches |
| Cache-warm clean | Remove build/asset-graph state | Remove workspace graph/generated state; retain compiled worker and user caches |
| No-op | Rerun with unchanged inputs | Rerun with unchanged inputs |

Cache-warm clean reruns generation with compiled workers and analyzer caches
retained. No-op reruns unchanged inputs after a successful build.

### 4-vCPU container: 1,539 generated outputs

Linux x64 container, 4 vCPU / 15 GB; Flutter 3.47.7 / Dart 3.13.5,
build_runner 2.16.2 and Analyzer 14.6.0. Root generation in a private pub
workspace uses freezed 4.0.3, json_serializable 6.15.2,
riverpod_generator 4.0.9 and mockito 5.8.1. Native uses the normal Dart launcher,
release linux-x64 binary and explicit `--jobs 2`. Both lanes were run in the
same session from the same stock-generated baseline.

Wall seconds below are medians of the supplied samples, with min–max and
sample count. Speedup is stock median divided by native median.

| Case | Stock seconds (range; n) | Native seconds (range; n) | Speedup |
| --- | ---: | ---: | ---: |
| Clean (AOT-cold) | 121.5 (113.5–130.7; 3) | 109.2 (108.0–110.4; 2) | 1.11x |
| Rebuild (analyzer caches retained) | 121.5 (113.5–130.7; 3) | 74.2 (72.2–74.8; 3) | 1.64x |
| No-op | 6.6 (6.5–6.7; 2) | 1.6 (1.5–1.6; 3) | 4.13x |
| One-file comment edit | 55.5 (55.3–55.9; 3) | 22.7 (22.3–23.5; 3) | 2.44x |
| Semantic edit affecting mocks and a Freezed union | 56.8 (one sample) | 29.6 (one sample) | 1.92x |

The rebuild retaining analyzer caches reuses the same stock-clean reference.
A stock rebuild immediately after switching frontends was excluded from no-op
samples; follow the [switching/reset guide](compatibility-cleanup.md).
These are small samples, with substantial between-session host-load drift.

### 8-core VM: 826 generated outputs

Linux x86_64 VM, 8 cores / 31 GiB; Flutter 3.47.5 / Dart 3.13.4;
24,779 planned actions. The application uses freezed, json_serializable, mockito,
riverpod_generator and source_gen.
Native uses the normal Dart launcher with a release binary override; exact
builder versions and worker count are unspecified. Both commands include
`--delete-conflicting-outputs`.

| Case | Stock seconds | Native seconds | Approximate speedup |
| --- | ---: | ---: | ---: |
| Clean (AOT-cold) | 56.8 (reference) | 51.8 (50.2–53.4; 2 runs) | ~1.1x |
| Cache-warm clean | 27.9 | 10.8 | 2.6x |
| No-op | 4.1 | 1.9 | 2.2x |
| One-file incremental | 17.1 | 5.0 | 3.4x |

For clean, 51.8 s is the native median; 56.8 s is the supplied stock reference,
not an aggregate of all stock samples. Stock clean observations ranged from
51.6–65.5 s across measurement windows. Other rows have no per-run samples or
repeat counts, so their variability cannot be quantified. These observations
do not establish a cross-version performance trend.
