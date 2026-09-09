# Current build_runner baseline

`scripts/benchmark_current_baseline.sh` measures the current stock
`build_runner` lane in an isolated temporary package. The fixture contains ten
independent `json_serializable` inputs so that `one-file` and `broad` represent
different dirty-action sets.

The default pins are:

| Item | Version or value |
| --- | --- |
| Dart SDK | selected by `DART_BIN` (the checked-in local toolchain is 3.13.0) |
| build_runner | 2.16.1 |
| build | resolved by the lockfile (4.0.10 with the default cache) |
| json_serializable | 6.14.1 |
| json_annotation | 4.12.0 |
| inputs | 10 Dart files |
| cache | `PUB_CACHE` (the repository-local cache by default) |

The script records a JSONL record and raw stdout/stderr for every measured
case. Each non-clean case performs an unmeasured warm-up build in the same
temporary package before changing inputs. `clean`, `no-op`, `one-file`, and
`broad` can be selected with `CASES`; `REPEATS` controls independent repeats.

```sh
scripts/benchmark_current_baseline.sh
CASES='clean no-op' REPEATS=3 scripts/benchmark_current_baseline.sh
STOCK_MODES='default force-jit force-aot' scripts/benchmark_current_baseline.sh
PUB_GET_OFFLINE=0 scripts/benchmark_current_baseline.sh
TRACE_MODE=1 CASES='clean' scripts/benchmark_current_baseline.sh
# Repeat the current watch smoke test without changing the fixture.
for repeat in 1 2 3; do
  FAST_BUILD_RUNNER_BIN="$PWD/rust/target/debug/fast_build_runner" \
    scripts/watch_smoke_current_json.sh
done
```

Current `build_runner` does not expose the old `--jobs` flag. The stock record
therefore declares `build_runner_parallelism=default`. The same script now
supports the rebased Rust worker through `LANE=fast`; `FAST_JOBS` records the
worker matrix without changing stock behavior.

```sh
LANE=fast FAST_JOBS=1 scripts/benchmark_current_baseline.sh
LANE=fast FAST_JOBS=2 scripts/benchmark_current_baseline.sh
LANE=fast FAST_JOBS=4 scripts/benchmark_current_baseline.sh
scripts/correctness_current_json.sh
FAST_BUILD_RUNNER_BIN="$PWD/rust/target/debug/fast_build_runner" \
  scripts/watch_smoke_current_json.sh
```

The single-repeat paired run on 2026-09-06 used the same Dart 3.13.0 SDK,
lockfile, cache, and ten-input fixture. Wall time was:

| Case | stock | fast jobs=1 | fast jobs=2 | fast jobs=4 |
| --- | ---: | ---: | ---: | ---: |
| clean | 35.67s | 11.04s | 11.51s | 12.02s |
| no-op | 0.827s | 0.011s | 0.010s | 0.011s |
| one-file | 0.778s | 1.396s | 1.462s | 1.642s |
| broad | 0.794s | 1.392s | 1.389s | 1.585s |

All four lanes produced byte-identical generated Dart files. The clean fast
lane is dominated by worker/kernel initialization; the incremental fast lanes
are currently dominated by action execution and do not benefit from jobs 2/4
on this ten-input fixture. These are initial single-repeat measurements, not a
release performance claim.

A three-repeat fast-lane run confirmed the same shape. The following are
medians; `wall/user/sys` are milliseconds and RSS is KiB:

| Case | jobs=1 | jobs=2 | jobs=4 |
| --- | ---: | ---: | ---: |
| clean | 11232 / 17017 / 1472 / 473820 | 11551 / 26446 / 2557 / 477392 | 12425 / 47467 / 4824 / 481836 |
| no-op | 10 / 6 / 4 / 10624 | 10 / 10 / 0 / 10624 | 11 / 4 / 3 / 10624 |
| one-file | 1383 / 1691 / 177 / 197196 | 1391 / 3129 / 328 / 162392 | 1559 / 6300 / 613 / 163504 |
| broad | 1330 / 1682 / 187 / 195488 | 1376 / 3088 / 306 / 161832 | 1705 / 6697 / 634 / 163024 |

The three repeated current-JSON watch smoke runs all passed for input change,
generated-output deletion, and rename, with byte-identical stock/Rust output.
The stock mode comparison also showed that `default` and `force-aot` use
`build_runner/aot` and have similar incremental timings (about 0.78--0.82s),
while `force-jit` was slower for incremental builds (about 2.30--2.51s).
This keeps the default stock AOT path as the reference and makes the fast
worker kernel cache the relevant warm-path optimization.

The existing `scripts/benchmark_freezed.sh` remains the legacy Freezed 3.x
stock/fast comparison. It is intentionally not combined with this current
baseline: Freezed 4.0.1 currently resolves through `analyzer_buffer` with an
Analyzer constraint below the Analyzer major required by build_runner 2.16.1.
