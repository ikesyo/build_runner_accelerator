# Helper snapshot validation and controlled startup measurements

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
Cold background compilation consumes CPU/memory; its cost is not measured by
these warmed comparisons. Helper snapshots are bound to training package
locations and require retraining after workspace relocation.

## Verification and integration fixes

- Rust: 99 tests pass; locked release build passes.
- Dart: analyze reports no issues; 94 tests pass.
- Quick verification with all arbitrary builder cases passes.
- Full verification passes all five suites: core, current-codegen,
  compatibility-lifecycle, compatibility-graph, compatibility-mapping
  (2256 seconds overall).
- Helper integration covers local JIT, shared restore, disablement, corruption
  and kernel fallback, dependency edits with preserved mtime, prewarm argument
  reuse, failed training, and native/detached summary-only training scope.

Integration binds keys to the package configuration URI and package roots
because app-jit ignores runtime `--packages`; includes SDK revision and follows
the executing `--dart` SDK; trains the already compiled kernel; preserves its
dependency metadata across JIT training; and forwards prewarm directory scope
so SDK-only startup does not train by resolving the whole workspace.
See [ADR 0019](../adr/0019-helper-snapshots.md).
