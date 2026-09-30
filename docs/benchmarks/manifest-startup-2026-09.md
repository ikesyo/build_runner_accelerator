# Manifest startup investigation, 2026-09-30

## Scope and evidence

This work starts from the supplied v0.7.0 large-Flutter-workspace report,
two anonymized action logs (3,133 records each), Rust metrics, and process
timelines. The application sources are not available here, so the original
827-output comparison cannot be rerun. Local validation uses repository
fixtures; no large-application speedup is claimed from those fixtures.

The timelines reproduce the report's critical-path observations:

| v0.7.0 run | First worker compile | First worker |
| --- | ---: | ---: |
| cold, round 2 | 12.6s | 46.2s |
| cold, round 6 | 14.7s | 50.8s |
| manifest regeneration, both supplied runs | none | 12.6s |

The action logs also reproduce the warm-build concern: the single largest
riverpod action takes 16.259s with one worker, while three actions exceed 2s
with four workers (6.865s, 16.725s, 10.136s). Their cumulative time increases
from 16.259s to 33.725s. This is a separate analyzer startup problem;
generator caching does not change those actions or worker parallelism.

## Implemented boundary

[ADR 0015](../adr/0015-manifest-generator-kernel-cache.md) adds a generator
kernel cache with dependency-content and SDK validation, source fallback,
and an opt-out for A/B measurements. Build configuration is still read on
every manifest regeneration.

[ADR 0016](../adr/0016-early-worker-catalog.md) adds shared lightweight catalog
selection on snapshot misses. Rust starts worker AOT before the heavyweight
generator compiles. On a probe cache miss, the generator can run that executable
in a separate factory-probe process, avoiding another compilation of the
builder imports. Readiness and exact source are checked independently; failure
uses the original source probe. Snapshot hits skip the additional selector.
Selection semantics remain shared Dart code using official BuildConfig,
rather than a second YAML/default implementation in Rust.

The new runtime stages separate `load-inputs`, `select-builders`, `entrypoint`,
`probe`, and `emit`. These timers start inside Dart main and exclude source
compilation. Rust separately measures kernel-cache validation or preparation.

## Local environment and initial isolated A/B

- Base: `0ef7164` (main after #69), package version 0.7.0.
- Linux x64; affinity exposes 3 CPUs, cgroup CPU quota is 2 CPUs;
  cgroup memory limit is 8 GiB. This differs from the supplied 4-vCPU host.
- Dart 3.13.4; Rust 1.98.1; locked repository/fixture dependency solutions.
- `json_serializable_app` fixture copied into a separate resolved workspace.
- Native frontend directly, `--mode rust --jobs 1`, with plan-only enabled
  and worker AOT disabled to isolate manifest generation.
- Probe cache prewarmed; source/snapshot runs alternated. No simultaneous
  verification or benchmark ran during the isolated A/B below.

| Generator route | Wall times | Median |
| --- | --- | ---: |
| Source | 14.082 / 17.346 / 15.017 / 16.269s | 15.643s |
| First kernel creation | 15.534s | one sample |
| Kernel hit | 1.327 / 1.332 / 1.323s | 1.327s |

Manifest and worker source were byte-identical in every measured run. This is
a native generator measurement, not a launcher-inclusive build benchmark.
The snapshot miss is not a demonstrated cold speedup: it still compiles the
generator and writes a kernel. The hit removes approximately 14.3s from this
fixture's generator route; the larger Flutter application needs its own A/B.

Kernel hit validation took about 0.11–0.12s in the final samples. The runtime
prefix through entrypoint emission took about 0.21–0.25s; builder selection
itself was about 0.014–0.016s. Probe cache lookup/identity work remains in the
runtime portion and is not removed by the kernel cache.

The committed reproduction script was then run separately with an empty
results/cache directory and the same resolved fixture/toolchain:

| Route | Wall times | Median |
| --- | --- | ---: |
| Source | 16.228 / 19.780 / 17.914 / 15.489s | 17.071s |
| Kernel miss | 16.083s | one sample |
| Kernel hit | 3.931 / 2.101 / 1.316s | 2.101s |

This second run also checked manifest and worker byte equality and restored
the previous generated files. The variation reinforces the need to compare
alternating runs and avoid extrapolating fixture times to the large application.

The cache is intentionally conservative about absolute source/config paths.
A fresh relocated checkout generally misses even with a shared cache root.
Repeated manifest regeneration at stable package roots is the primary target.

### Reproduction

Resolve the chosen fixture and select the same toolchain/cache for all runs.
Run without concurrent builds or source edits in that workspace:

```bash
export DART_BIN=/absolute/path/to/dart
export CARGO_BIN=/absolute/path/to/cargo
export PUB_CACHE=/absolute/path/to/pub-cache
export BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/release/build_runner_accelerator"
(cd fixtures/json_serializable_app && "$DART_BIN" --suppress-analytics pub get)
bash scripts/benchmark_manifest_generator.sh
```

`MANIFEST_BENCHMARK_ROOT` selects an already-resolved workspace and
`MANIFEST_BENCHMARK_RESULTS` selects an empty results directory. The script
prewarms probe results, creates an isolated cache, alternates source and kernel
routes four times, checks manifest/worker bytes, records raw metrics, and
restores any pre-existing manifest and worker entrypoint. Plan-only skips
generated-output and graph commits. This is a phase benchmark; use the normal
build benchmarks for launcher/worker/build behavior.

## Rust-side early builder selection

The requested Rust route can target the early **factory catalog**, rather than
porting all manifest generation. The catalog needs the union of selected
normal/post-process builder IDs, import URIs, factory names, and builder kind.
It does not need runtime output mappings, probes, triggers, phase ordering,
file scans, `generate_for` matching, or generated-output planning. In the
current selector, selection for each target is independent of other targets;
the emitter sorts catalog entries by ID. Target SCC ordering is therefore
not needed just to produce that union, although final manifest validation
must continue to perform it.

Rules that cannot be skipped:

1. Load all resolved packages, root `dependencies` + `dev_dependencies`, and
   non-root runtime dependencies for `auto_apply: dependents`.
2. Use build_config-compatible defaults and name normalization for builder
   definitions, targets, configured builder keys, and `applies_builders`.
3. Honor per-target `auto_apply_builders`, explicit enable/disable precedence,
   the four auto-apply modes, and recursive applies-builders selection.
4. Preserve non-root `build_to: source` exclusions and the exclusion of cache
   builders which apply a source builder.
5. Ignore unavailable dev-only definitions as the current selector does.
   Keep relative imports only for root definitions, and distinguish normal
   and post-process factories. Preserve multi-factory IDs (`#factory<n>`).
6. Emit the same source bytes and escaping as the Dart emitter, including
   deterministic import grouping and sorted IDs.

Rust currently consumes normalized manifest JSON; it has no general YAML
parser dependency or implementation of build_config defaults. Its existing
`Workspace` package list and fingerprint can be reused, but parsing alone
would not establish selection compatibility.

### Bounded implementation candidate

Keep the official Dart generator authoritative. Put a small Rust catalog
selector behind an opt-in and support a declared subset first. Unknown YAML
shapes/defaults should decline early emission and use the normal path. After
selection, Rust may write the worker entrypoint atomically and start early AOT
while the Dart generator compiles/loads and performs full validation/probing.
Compare the final worker bytes with the early source before treating the
early artifact as reusable; a mismatch must use the normal final compile.
An unsupported manifest must still fail/fall back exactly as today.

The fingerprint and AOT key must always be computed from the exact source
that was compiled. An all-definition superset is not a drop-in shortcut:
unselected imports/factories can fail compilation, and an early superset
differs from the final selected source, invalidating worker AOT reuse. Keeping
that superset as the permanent final catalog would be a separate architecture
and compatibility decision.

Before enabling by default, differential tests should compare early worker
bytes against the Dart selector across multiple targets, dependencies,
explicit disables, all auto-apply modes, applies-builders recursion,
post-process builders, multi-factory IDs, and relative root imports. Include
unknown/invalid configurations, clean/no-op/incremental output equality, and
generator failure while an early compile is in flight. Benchmark both
snapshot-cold and snapshot-warm paths so an extra early-selection pass does
not erase the warm startup improvement.

### Lower-risk control experiment

A local scratch prototype reuses the existing Dart graph loader, definition
resolver, selector, and emitter, excluding trigger/mapping imports. It only
emits a catalog; it leaves source-pattern and full manifest validation to the
original generator. Its compiler depfile contains 136 source files, compared
with 799 for the full generator, and contains no Analyzer imports. Three
source launches took 2.182 / 1.765 / 1.831s under concurrent validation load;
these are exploratory timings, not a controlled performance result. Its
worker bytes matched the JSON fixture's full generator output.

This control motivated the implemented shared selection library and lightweight
helper. Rust runs the helper on generator snapshot misses and source fallback;
the full generator uses the same resolver, selector and emitter. A native Rust
YAML selector remains unimplemented. This keeps the official configuration
semantics while moving worker AOT startup ahead of full generator compilation.

## Completed cold builds

`scripts/benchmark_cold_startup.sh` creates an isolated copy of the resolved
JSON fixture, generates a stock reference, and alternates the same native
binary with both optimizations disabled against the default route. Each cold
run starts with an empty workspace build/manifest/worker cache, a fresh shared
generator/probe/AOT cache and a fresh analyzer state directory. SDK and pub
dependencies are resolved, and OS page caches are warm; this is tool-cache-cold,
not a cold operating-system boot. The native frontend is measured directly,
including completed output generation, excluding the public Dart launcher.
No concurrent verification runs during these measurements.

An early-selection-only control did **not** improve completed cold builds:
three alternating samples gave medians of 60.601s (source baseline) and
62.686s (snapshot miss plus early catalog). On this 2-CPU quota, overlapping
compiler CPU use offsets the earlier AOT start. Entrypoint timing alone is
therefore insufficient evidence of a cold speedup.

Adding compiled-worker factory probing removes a third compilation of the
builder imports. A first three-pair run gave cold medians of 68.017s versus
58.075s (14.6% reduction), with all generated bytes equal to stock. The final
reproduction, after matching source-probe request order and independent
options decoding per factory, is recorded below.

Final three-pair reproduction, `json_serializable_10_app`, Dart 3.13.4,
Rust 1.98.1, `--mode rust --jobs 1`, same 2-CPU/8-GiB executor. Both modes
force synchronous worker AOT with `BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1`:

| Case | Source baseline median | Default median |
| --- | ---: | ---: |
| Completed cold build | 69.831s | 57.386s |
| No-op | 0.017s | 0.008s |
| One source comment changed | 0.469s | 0.369s |
| All source comments changed | 0.472s | 0.419s |

Cold samples were 75.833 / 68.858 / 69.831s for the baseline, and
57.386 / 52.605 / 57.539s for the default route: a **17.8%** median reduction.
Every output comparison passed. Rust dispatched early AOT after 2.557 / 1.797 / 2.068s
in the default samples, and all three probes used `executor=worker-aot`.
One baseline optional runtime-type probe reached its existing 30-second
timeout; the manifest still succeeded and generated the stock outputs. That
completed build remains included in the measurements. The small warm-case
timings vary between repetitions; these routes reuse a valid manifest and do
not execute either generator optimization, so no warm scheduling speedup is
claimed from this change.

```bash
(cd fixtures/json_serializable_10_app && "$DART_BIN" --suppress-analytics pub get)
JOBS=1 COLD_BENCHMARK_REPEATS=3 bash scripts/benchmark_cold_startup.sh
```

`COLD_BENCHMARK_ROOT` selects a resolved JSON fixture;
`COLD_BENCHMARK_RESULTS` must be a fresh results directory. Per-run logs and
`measurements.json` record completed cold, no-op, one-file and broad incremental
cases and byte equality to the stock reference. The baseline sets both
`BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT=0` and
`BUILD_RUNNER_ACCELERATOR_EARLY_CATALOG=0`; default measurements enable both.
Both modes use the same binary, SDK, locked packages and `--jobs 1`.

## Validation

Local checks passed with the above toolchain/cache:

```bash
cargo test --locked --manifest-path rust/Cargo.toml
cargo build --release --locked --manifest-path rust/Cargo.toml
dart --suppress-analytics test
dart --suppress-analytics analyze lib bin test tool
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
bash scripts/correctness_manifest_snapshot.sh
bash scripts/correctness_early_catalog.sh
VERIFY_LEVEL=full VERIFY_FULL_SUITES=current-codegen bash scripts/verify.sh
VERIFY_LEVEL=full VERIFY_FULL_SUITES=compatibility-graph bash scripts/verify.sh
rustfmt --edition 2024 --check rust/src/build.rs rust/src/manifest_generator.rs rust/src/frontend.rs
git diff --check
```

The final Rust suite contains 83 tests and the Dart suite contains 72 tests.
On this managed executor, verification uses an explicit writable
`BUILD_RUNNER_ACCELERATOR_CACHE` and `ANALYZER_STATE_LOCATION_OVERRIDE`, since
the default home directory is read-only. Network permission is also needed
for pub resolution and the release downloader's local HTTP-server tests.

The standard JSON benchmark was run once, with `COUNT=10 JOBS=1` and
`BUILD_RUNNER_ACCELERATOR_METRICS=1`, using
`bash scripts/benchmark_json_serializable.sh`. All output comparisons passed:

| Case | Stock | Native |
| --- | ---: | ---: |
| Initial clean, cold tool/build caches | 64.924s | 73.127s |
| No-op | 1.599s | 0.233s |
| One source comment changed | 1.403s | 0.436s |
| All 10 source comments changed | 1.369s | 0.438s |

This existing script invokes the native binary through the worker shell
adapter, rather than the public Dart launcher. The first clean includes stock
build-script compilation and native generator/probe/worker AOT/analyzer cache
setup. Its cold paths differ between frontends; this table records behavior
and output equality, not a before/after speedup of the snapshot change.
The later cases have warm caches. RSS was unavailable in the shell timing
fallback on this executor. Raw measurements remain local.

The two required quick verification commands passed, including all arbitrary
builder cases. The full `current-codegen` suite passed Freezed and Riverpod
correctness and watch checks. The full `compatibility-graph` suite passed target
cycles, dependency targets and applies-builders checks. Focused catalog checks
also passed with the default AOT path, kernel hits, disabled/JIT/background/
explicit-AOT policies, helper failure, source mismatch, generator failure while
AOT compilation was in flight, and auto-mode stock fallback.

The original large application, minimum Dart SDK and macOS/Windows execution
have not been rerun. The complete full-suite union and wider builder benchmark
matrix remain release/merge checks; this local validation ran the two full
subsets above. No remote push or merge is part of this experiment.
