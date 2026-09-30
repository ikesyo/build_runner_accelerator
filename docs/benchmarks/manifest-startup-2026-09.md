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
every manifest regeneration. The early worker AOT/probe overlap is preserved.

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

This confirms that a lightweight entrypoint stage is plausible without
duplicating YAML semantics in Rust. A follow-up could extract the shared
selection helpers into an Analyzer-independent library and let Rust run
that small helper before the full generator on snapshot misses. It should
be compared with the bounded native selector above. Neither early-selection
route is enabled in this change; the committed optimization is the kernel
cache, with metrics and a reproducible benchmark.

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
rustfmt --edition 2024 --check rust/src/build.rs rust/src/manifest_generator.rs
git diff --check
```

The final Rust suite contains 83 tests and the Dart suite contains 68 tests.
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

The original large application, minimum Dart SDK, macOS/Windows execution,
and full release/merge suite (`VERIFY_LEVEL=full`, watch and wider builder
benchmark matrix) have not been rerun. No remote push or merge is part of
this experiment.
