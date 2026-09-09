# Current build_runner baseline

`scripts/benchmark_current_baseline.sh` measures the current stock
`build_runner` lane in an isolated temporary package. The fixture contains ten
independent `json_serializable` inputs so that `one-file` and `broad` represent
different dirty-action sets.

The default pins are:

| Item | Version or value |
| --- | --- |
| Dart SDK | selected by `DART_BIN` (the reference run used Dart 3.13.0) |
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
  BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/debug/build_runner_accelerator" \
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
BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/debug/build_runner_accelerator" \
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
The stock default AOT path remains the reference. The launcher now enables
AOT by default for native invocations; the explicit AOT measurements below
cover that release path.

The AOT worker measurements use the same fixture and cache conditions:

```sh
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1 \
  LANE=fast FAST_JOBS=1 \
  BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/debug/build_runner_accelerator" \
  scripts/benchmark_current_baseline.sh
scripts/correctness_aot_worker.sh
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1 \
  BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/debug/build_runner_accelerator" \
  scripts/watch_smoke_current_json.sh
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background \
  BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/debug/build_runner_accelerator" \
  scripts/correctness_aot_background.sh
```

On 2026-09-06, the AOT lane's cold `clean` was `26.51s` because the
workspace-local executable was compiled during that case. The benchmark's
non-clean cases compile the AOT worker during their unmeasured warm-up, so
their measured three-repeat medians were:

| Case | AOT jobs=1 wall | user / sys | peak RSS |
| --- | ---: | ---: | ---: |
| no-op | 9.8ms | 8.4 / 4.0ms | 10.4MiB |
| one-file | 87.7ms | 47.1 / 38.5ms | 45.6MiB |
| broad | 101.7ms | 79.6 / 30.0ms | 45.4MiB |

One broad repeat was an `865ms` outlier; all AOT cases produced the same
`51d4d65d...` output hash as stock. A direct worker handshake on the same
fixture measured medians of `9.49s` for the script, `0.178s` for the kernel,
and `0.009s` for the AOT executable. The launcher now defaults native invocations to AOT. Cold compile cost and
cross-platform / cross-workspace memory behavior still need broader
evaluation, so these measurements are not a release-wide performance
guarantee.

### Launcher-inclusive post-optimization spot check

After moving release-download dependencies off the normal import path, a
launcher-inclusive run was remeasured on 2026-09-09. Both lanes used the same
ten-input `current_json_app` fixture, Dart 3.13.3, build_runner 2.16.1, and the
repository pub cache. The accelerator used the optimized Rust release binary
and was invoked through `dart run bin/build_runner_accelerator.dart` with
`FAST_LAUNCHER=1`; its clean case includes the workspace-local worker AOT
compilation. The one-file case was measured after an unmeasured warm build in
each lane. The clean row is one run; the warm rows are three-repeat medians.

| Case | stock wall | accelerator launcher wall | speedup |
| --- | ---: | ---: | ---: |
| clean, including AOT cache generation | 36,873 ms | 31,626 ms | 1.17x |
| warm no-op | 1,206 ms | 486 ms | 2.48x |
| warm one-file change | 1,018 ms | 618 ms | 1.65x |

This is a single paired spot check rather than a release guarantee. The
steady-state result is now faster even with the launcher included; the
remaining warm incremental time is dominated by the Dart builder and resolver,
not Rust planning. `BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0` was also exercised
after the change and continued to complete successfully, although it is
expected to be slower for dirty builds.

The benchmark script supports the same distinction explicitly:
`FAST_LAUNCHER=0` measures the native frontend directly, while
`FAST_LAUNCHER=1` includes the normal Dart script launcher. Neither setting
means that the launcher itself was AOT-compiled.

### CI AOT prewarm

The CI lane is intentionally split into key computation, cache restore,
synchronous prewarm, and cache save:

```sh
key=$(scripts/aot_cache_key.sh "$PWD")
scripts/aot_prewarm.sh "$PWD"
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1 scripts/run_rust_frontend.sh \
  build --root "$PWD" --mode rust
```

The cache should contain `.dart_tool/build_runner_accelerator/aot-sdk/`,
`dynamic_worker.dart`, and `builder-manifest.json`. The key includes OS/arch,
SDK identity, stable package configuration, lockfile/manifest inputs, and the
generated worker digest; it contains no checkout or SDK absolute path. The
version-2 metadata sidecar records logical package/workspace dependencies and
content digests, and the SDK facade links are rebound when a restored artifact
is used. `scripts/correctness_aot_prewarm.sh` covers prewarm compile wait,
relocated cache reuse, facade rebind, and worker-source invalidation. The provider-specific restore/save policy is covered by
[ADR 0005](adr/0005-performance-and-validation-policy.md).

### Local background AOT

For local cache misses, `BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background` starts the
script worker immediately and launches a detached `aot-prewarm` helper. The
first build therefore does not wait for AOT compilation. Once the helper has
published the executable, the next build reuses it; a long-running watch pool
also switches to AOT on its next rebuild. A helper failure is isolated from
the foreground build and leaves the script fallback available for a later
retry. `scripts/correctness_aot_background.sh` verifies the compile gate,
script fallback, artifact publication, and next-invocation AOT reuse.

The existing `scripts/benchmark_freezed.sh` remains the legacy Freezed 3.x
stock/fast comparison. It is intentionally not combined with this current
baseline: Freezed 4.0.1 currently resolves through `analyzer_buffer` with an
Analyzer constraint below the Analyzer major required by build_runner 2.16.1.
