# Helper snapshot validation and controlled startup measurements

The [external large-application report](helper-snapshots-external-2026-10.md)
records current-head `12a08db` results against main `ab079ec`, including warm
prewarm gains and measured contention with an immediate follow-up build.

Measured on 2026-10-02 against main `f7f4032`, after applying the attached
`9cf5c38` implementation and fixing helper cache identity and training scope.
Resident workers retain the existing AOT policy and compilation pipeline.

## Conditions and reproduction

- Linux x64, Dart 3.13.3, Rust 1.98.1, release native frontend.
- Fixture: `fixtures/json_serializable_10_app`, copied into one isolated
  workspace with the repository path dependency resolved offline.
- N=3 medians, alternating source/snapshot order; `--jobs 4`.
  Clean native metrics confirmed four active workers.
- One SDK and pub cache for stock and native. Helpers are trained once;
  worker AOT, analyzer byte store, SDK summary and OS caches are warm.
- `BUILD_RUNNER_ACCELERATOR_METRICS=1`, worker AOT enabled, and
  `BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT=0` so every clean generation
  exercises the early catalog. The comparison changes only
  `BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT=0/1`.
- Clean removes outputs, manifest, graph and generated cache assets while
  retaining compiled helper/worker artifacts. One-file and broad cases append
  comments to one/all source inputs. Every measured build checks generated
  bytes against a stock build_runner reference.

From the repository root, using its selected toolchains:

```bash
export ANALYZER_STATE_LOCATION_OVERRIDE="$PWD/.toolchains/analysis-cache"
export BUILD_RUNNER_ACCELERATOR_CACHE="$PWD/.toolchains/accelerator-cache"
export BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/release/build_runner_accelerator"
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
VERIFY_LEVEL=full bash scripts/verify.sh
JOBS=4 HELPER_BENCHMARK_RESULTS=/tmp/helper-benchmark-verified \
  bash scripts/benchmark_helper_snapshot.sh
```

The benchmark invokes the native frontend directly:

```text
rust/target/release/build_runner_accelerator build
  --root /tmp/helper-benchmark-verified/fixture
  --dart .toolchains/dart/dart-sdk/bin/dart --mode rust --jobs 4
```

The actual command uses absolute executable paths. Choose a fresh results
directory for each run. Raw logs, `measurements.json` and `summary.json` remain
local in that directory.

## Helper execution

Times include the Dart process launch and helper execution, excluding Rust
artifact selection/validation. Analysis runs use a warm byte store.
Catalog output bytes matched across source/kernel/JIT.

| Helper | Source (s) | Kernel (s) | JIT (s) |
| --- | ---: | ---: | ---: |
| Worker catalog | 1.273 | 0.215 | 0.114 |
| Analysis prewarm | 11.380 | 1.118 | 0.415 |

JIT reduces these source startup medians by 91.0% and 96.4%, respectively.

## Complete native builds

These times include Rust helper cache validation and the authoritative Dart
manifest generator. All 24 measured builds produced byte-identical outputs
to stock; each snapshot clean log confirmed `artifact=jit cache=local`.

| Case | Helpers as source (s) | Warm snapshots (s) |
| --- | ---: | ---: |
| Clean | 10.203 | 9.317 |
| No-op | 0.0036 | 0.0036 |
| One-file incremental | 0.265 | 0.267 |
| Broad incremental | 0.318 | 0.318 |

The controlled clean median improves by 8.7%. No-op and incremental cases
show no material difference, as their valid manifests avoid catalog generation.
This is a small-fixture experiment with generator snapshots deliberately
disabled, not a default launcher-inclusive or fully cold-cache measurement.
Cold background compilation consumes CPU/memory; see the separate first-build
comparison below. Helper snapshots are bound to training package
locations and require retraining after workspace relocation.

## First cold build and detached training

Measured after merging main `ab079ec` into this PR. Every trial uses a new
workspace, empty native/shared/helper/Analyzer caches, and no SDK summary.
SDK/pub dependencies and OS page caches remain warm; pub resolution and the
stock reference build are outside timing. The native frontend runs directly
with `--jobs 4`, default manifest and worker AOT policies, metrics enabled,
and only `BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT=0/1` changed. Trials are
sequential with alternating order, N=3 per mode. Detached training is allowed
to finish before the next trial. Linux cgroup CPU quota is 2 CPUs, memory
limit 8 GiB; `available_parallelism` sees fewer than 4 CPUs, so default SDK
summary prewarm is inactive. This comparison exercises catalog training;
analysis-prewarm training is covered by integration tests, not this timing.

| Training policy | Helpers disabled (s) | Helpers enabled (s) | Difference |
| --- | ---: | ---: | ---: |
| Immediate background creation | 36.730 | 38.610 | +5.1% |
| Creation after foreground build | 35.762 | 35.873 | +0.3% |

Individual foreground times, in trial order within each mode:

- Immediate disabled: 35.908, 36.730, 37.679 s; enabled: 38.610, 37.082, 39.610 s.
- Deferred disabled: 36.024, 35.718, 35.762 s; enabled: 35.873, 35.933, 35.810 s.

Immediate training consumed resources during the cold build even though the
frontend did not wait for it. The revised policy queues helper misses and
starts detached compilation after the foreground operation returns. Watch
releases the queue after each build, allowing training while the watcher
waits. The integration test checks the launch comes after the foreground
completion message, and that training finishes while watch remains alive.

After deferral, catalog training continues for about 0.8–0.9 s after native
exit. Median elapsed time from build start until background completion is
36.737 s for enabled helpers (foreground median 35.873 s). All 12 measured
builds matched stock output bytes; all enabled trials produced catalog JIT
metadata. The +0.3% foreground difference is small in this sample, not a
guarantee across machines or larger projects. Starting another build while
training is still active can contend with that training. The separate warm
measurements above remain measurements of already prepared artifacts.

Reproduce the revised policy with a release frontend and a fresh results path:

```bash
python3 scripts/benchmark_helper_cold.py /tmp/helper-cold-results \
  --repeats 3 --jobs 4 --expect-deferred
```

The harness records foreground and background completion times, raw build
logs, `measurements.json` and `summary.json`. The immediate-policy raw logs
are in `/tmp/helper-cold-before`, and revised-policy logs in
`/tmp/helper-cold-after` for this session.

## Verification and integration fixes

- Rust: 99 tests pass; locked release build passes.
- Dart: analyze reports no issues; 94 tests pass.
- Quick verification with all arbitrary builder cases passes.
- Full verification passes all five suites: core, current-codegen,
  compatibility-lifecycle, compatibility-graph, compatibility-mapping
  (2256 seconds overall, before the deferred-training follow-up).
- Helper integration covers local JIT, shared restore, disablement, corruption
  and kernel fallback, dependency edits with preserved mtime, prewarm argument
  reuse, failed training, and native/detached summary-only training scope.
- After deferring training: 99 Rust tests and the locked release build pass;
  quick verification with all arbitrary builder cases and static analysis
  passes again. Helper integration additionally checks launch ordering after
  foreground completion and regenerated JIT metadata while watch stays alive.

Integration binds keys to the package configuration URI and package roots
because app-jit ignores runtime `--packages`; includes SDK revision and follows
the executing `--dart` SDK; trains the already compiled kernel; preserves its
dependency metadata across JIT training; and forwards prewarm directory scope
so SDK-only startup does not train by resolving the whole workspace.
See [ADR 0023](../adr/0023-helper-snapshots.md).
