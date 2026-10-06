# Development

The repository is tested with a locally selected Dart SDK, Rust toolchain, and
pub cache. Do not rely on a different global SDK when comparing stock
`build_runner` with the native frontend.

## Toolchain selection

Repository scripts resolve tools in the following order:

1. An explicit environment variable such as `DART_BIN` or `CARGO_BIN`.
2. The repository-local toolchain under `.toolchains/`, when present.
3. The corresponding executable on `PATH`.

The cache and Rust home variables can also be overridden explicitly:

```bash
export DART_BIN=/absolute/path/to/dart
export CARGO_BIN=/absolute/path/to/cargo
export PUB_CACHE=/absolute/path/to/pub-cache
export RUSTUP_HOME=/absolute/path/to/rustup
export CARGO_HOME=/absolute/path/to/cargo-home
```

AOT-specific scripts that inspect SDK files also accept `DART_SDK`.

The 0.1.x package line supports Dart `>=3.11.0 <4.0.0`. Its tested core build
stack is bounded as follows:

- `analyzer >=13.3.0 <15.0.0`
- `build >=4.0.9 <5.0.0`
- `build_config >=1.3.2 <1.4.0`
- `build_runner >=2.16.1 <2.17.0`
- `package_config >=2.2.0 <4.0.0`

The `build_runner` upper bound is intentional: the worker uses private
`build_runner` interfaces whose signatures changed in 2.15.x and may change
again in later minor releases. The release workflow validates a minimum solution with Dart
3.11.0 and `dart pub downgrade`, and a current solution with Dart 3.13.3 and
`dart pub upgrade`. Rust contributors should use the repository-pinned Rust toolchain. The pin
is defined in `rust-toolchain.toml`; CI and release workflows use the same
exact version.

### analyzer 14.5 and stock build_runner

The worker and analysis prewarm use `AnalysisOptionsBuilder` to support
analyzer 14.5.0 without the removed `AnalysisOptionsImpl.contextFeatures`
setter. The existing analyzer range remains unchanged. The builder import
uses analyzer's `src/generated/engine.dart` export so it also works with
13.3.0, before `build_resolvers.dart` exported the builder. Both context and
non-package features are set explicitly to preserve the older setter's behavior.

As of 2026-10-06, the latest published build_runner is 2.16.1. It still
uses the removed setter in `src/build/resolver/resolvers_impl.dart`, so
`dart pub upgrade` resolves analyzer 14.5.0 but `dart run build_runner --help`
fails to compile. This also affects stock fixture builds/watch and package
tests importing that resolver. The accelerator's options migration does not
repair that upstream source. Upstream build_runner main has migrated to the
builder, but its 2.16.2-wip changes have not been released and include unrelated
dependency/API changes. Validate the stock paths again when a compatible
release is available; do not treat an accelerator-only analysis pass as a
stock fallback compatibility pass.

## Local checks

```bash
dart pub get
dart analyze
dart test
cargo test --manifest-path rust/Cargo.toml
```

The default verification loop builds the frontend once and reuses it:

```bash
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
VERIFY_LEVEL=full bash scripts/verify.sh
VERIFY_LEVEL=full VERIFY_FULL_SUITES=compatibility-graph bash scripts/verify.sh
```

The full level is the union of `core`, `current-codegen`,
`compatibility-lifecycle`, `compatibility-graph`, and
`compatibility-mapping`. `VERIFY_FULL_SUITES` accepts a comma-separated subset
so CI can shard those suites without maintaining a second list of probes.

### CI coverage

Pull request CI separates verification by responsibility:

| CI entry | Scope | Frequency |
| --- | --- | --- |
| `Baseline integration and package smoke` | Quick verification, arbitrary builder cases, and published-package smoke | Pull requests and pushes to `main` |
| `Freezed and Riverpod compatibility` | Freezed and Riverpod correctness plus watch smoke | Pull requests and pushes to `main` |
| `Compatibility suite (lifecycle, graph, mapping)` | `compatibility-lifecycle`, `compatibility-graph`, and `compatibility-mapping`, one selector per parallel step | Pull requests and pushes to `main` |
| `Core correctness` | The `core` full suite: JSON serializable cases, generic watch smoke, and built_value | Nightly and `workflow_dispatch` |

The compatibility job intentionally selects one `VERIFY_FULL_SUITES` value per
parallel step. It does not rerun the baseline or current-codegen suites. The
periodic core workflow uses the canonical `core` selector so the missing core
coverage is exercised without expanding the required pull-request checks.

Run the relevant fixture scripts when changing graph, worker, watch, or
builder behavior:

```bash
bash scripts/watch_smoke.sh
bash scripts/benchmark_matrix.sh
BUILDERS=optional bash scripts/benchmark_matrix.sh
```

For performance changes, enable
`BUILD_RUNNER_ACCELERATOR_METRICS=1` and record clean, no-op, one-file, and
broad incremental cases. Keep raw JSONL and trace artifacts local. Update
the public summary in [`benchmarks.md`](benchmarks.md) only from a
reproducible launcher-inclusive run; detailed experiments belong in
[`benchmarks/experiments-2026-09.md`](benchmarks/experiments-2026-09.md).

To isolate manifest-generator startup, resolve the selected fixture first and
run `bash scripts/benchmark_manifest_generator.sh`. This native phase benchmark
alternates source and cached-kernel routes and checks manifest/worker equality;
it is separate from launcher-inclusive build measurements. Details and the
Rust early-selection investigation are in
[`benchmarks/manifest-startup-2026-09.md`](benchmarks/manifest-startup-2026-09.md).

For the combined cold-start change, resolve `fixtures/json_serializable_10_app`
and run `bash scripts/benchmark_cold_startup.sh`. It builds a stock reference
and alternates both optimizations disabled against the default route, with
empty tool/build/analyzer caches for each cold build. It also records no-op,
one-file and broad incremental cases, checking generated bytes throughout.
The resolved SDK/pub cache and OS page cache are warm. `COLD_BENCHMARK_ROOT`,
`COLD_BENCHMARK_RESULTS`, `COLD_BENCHMARK_REPEATS` and `JOBS` select the inputs.
This measures the native frontend directly, excluding the Dart launcher.

For fully cold AOT builds against both stock and a previous Dart implementation,
use `scripts/benchmark_cold_aot.py`. Supply a source checkout (or extracted Git
archive) through `--baseline-root`, the real SDK executable through `--dart`,
and a release frontend through `--native`. Each repeat stages three isolated
workspaces and empty accelerator/analyzer caches, runs offline pub resolution
outside timing, and measures the normal `dart run` commands. The harness checks
AOT artifacts, normalized manifest/worker equality, and stock output bytes for
cold, no-op, one-file, and broad cases. It alternates lane ordering between
repeats. `--fixture` also supports the tracked Freezed and Riverpod fixtures.

For fresh-checkout reuse on a warm machine, use
`bash scripts/benchmark_cross_workspace_startup.sh` with a separately built
main binary and package source root. The script compares clean, no-op,
one-file and broad incremental builds against stock output bytes; commands
and cache conditions are recorded in
[`cross-workspace-startup-2026-10.md`](benchmarks/cross-workspace-startup-2026-10.md).

To compare build-cache-cold main/candidate implementations in the same fixture
and cache paths, use `scripts/benchmark_cold_build.py`. Prepared AOT and
`--aot-cold` comparisons are separate; the latter includes manifest/probe/kernel
and worker compilation. It alternates lanes and checks output bytes for cold,
warm clean, no-op and real one-file/broad edits. See
[cold Builder lookup measurements](benchmarks/cold-builder-lookups-2026-10.md)
for commands, distributions and cache conditions.
The same harness supports the tracked Riverpod fixture with
`--fixture-kind riverpod`; `--retain-dep-parse` keeps directive caches while
clearing the analyzer byte store. See
[conditional directive collection measurements](benchmarks/resolver-conditional-directives-2026-10.md)
for isolated main/candidate workers, collector diagnostics and cold-cache limits.
For collector digest reuse, compare against the unchanged PR #84 worker, and
use `--stock-check` to prepare untimed stock references for each edit case.
`scripts/prepare_resolver_digest_fixture.py --root <new-disposable-directory>`
creates 24 Riverpod entrypoints importing eight shared API pairs through
conditional URIs (16 shared sources); `--ordinary-imports` instead prepares
eight shared sources with ordinary imports. Resolve it
with the same pub cache, prepare both AOT workers outside timing, and pass
`--fixture-kind riverpod-shared` to the comparison harness. Metrics/trace must
remain disabled for timings; use a separate `--metrics` invocation for digest
computation/reuse counts and collector stage times. See
[digest reuse measurements](benchmarks/resolver-content-digest-2026-10.md).

For cycle-graph read work, `scripts/prepare_cycle_read_fixture.py --root
<new-disposable-directory>` prepares 64 mixed Riverpod/Freezed/JSON inputs
sharing 144 conditional/transitive sources. Use `benchmark_cold_build.py
--fixture-kind riverpod-cycle --stock-check` with isolated main/candidate AOT
workers for jobs 2/4 and the full clean/no-op/one-file/broad comparison.
`--aot-cold` with both package roots includes worker/manifest preparation.
Use a separate `--metrics --trace` run for phased-load content versions,
visibility, content conversion/hash and update-notification boundaries.
`--trace` requires `--metrics` to prevent traces entering timing comparisons.
See [cycle dependency read measurements](benchmarks/cycle-dependency-reads-2026-10/README.md)
for cache conditions, results, and limits.

For frontend wall attribution, set `BUILD_RUNNER_ACCELERATOR_WALL_TRACE=1`
and capture stderr. This flag is independent of worker metrics/analysis trace;
leave those disabled when diagnosing ordinary request/response and decode cost.
`python3 scripts/summarize_frontend_wall.py <log>` partitions intervals on one
Rust monotonic clock, reports per-worker batch boundaries and the latest batch
finish for each phase, and preserves unattributed gaps. It rejects dropped or
truncated traces. Events are buffered (up to 100,000 per build) and flushed after
the native build interval; process/launcher timing includes that flush. For
watch, each build has its own origin and excludes watch's earlier manifest/pool
setup. `receive_frame` includes waiting, frame reads and control-JSON parsing;
it does not measure worker CPU. Keep wall traces disabled in speed comparisons.

`scripts/benchmark_frontend_regen.py` measures the supplied regen definition in
a disposable cycle-read fixture: remove all workspace accelerator state and
source outputs, retaining shared caches. Its native, `--launcher`, and
`--diagnostic` modes are separate conditions; diagnostic mode compares disabled,
wall-only, and wall+metrics on the same candidate. It checks all outputs against
an untimed stock reference. See
[frontend wall attribution](benchmarks/frontend-wall-2026-10/README.md) for
boundaries, measured overhead, results, and application limits.

For detailed per-worker diagnostics, set both
`BUILD_RUNNER_ACCELERATOR_METRICS=1` and
`BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE=1`. Action JSON then includes worker
PID/RSS, Analyzer file-content paths, byte-store miss keys, uncached can-read
assets and Linux cumulative CPU ticks (`getconf CLK_TCK` converts to seconds).
Driver creation and resolver replacement counts help distinguish initialization
from reuse. File-content paths and linked bundle misses do not directly count
parsed libraries. Keep these traces separate from performance timing runs.

For unexpectedly large native action plans, use the pre-worker diagnostics:

```bash
BUILD_RUNNER_ACCELERATOR_PLAN_ONLY=1 \
  dart run build_runner_accelerator build --mode rust
```

This prints graph, planner, visibility, and action-generation counts plus
builder/target breakdowns and Linux RSS samples to stderr, then exits before
starting the Dart worker or changing outputs. `PLAN_ONLY` enables the plan
metrics; it is intended for investigation rather than a build result.

## Release checks

The release workflow builds one archive per target in
[`launcher-and-release.md`](launcher-and-release.md), checks the
native `--version` and `--help` paths, then creates the signed manifest and
checksums. The signing private key must only be supplied through the CI secret;
the public key is pinned in the Dart package.

## Release flow

Releases are prepared with [tagpr](https://github.com/Songmu/tagpr). Pushes to
`main` create or update one release pull request. The pull request updates the
version in `pubspec.yaml`, `lib/src/launcher.dart`, and `rust/Cargo.toml`, and
adds the generated entry to `CHANGELOG.md`. Review and merge that pull request
when the release contents are ready.

After the release pull request is merged, the tagpr workflow tags the merge
commit. It then calls the reusable release workflow with that exact tag. The
five native targets are built, the signed manifest and checksums are produced,
and the GitHub Release is published with the artifacts. `release = false` in
`.tagpr` is intentional: tagpr creates the tag, while the release workflow
publishes the asset-bearing release after signing.

Enable “Allow GitHub Actions to create and approve pull requests” in the
repository's Actions settings before the first run. The existing tag trigger
in `.github/workflows/release.yml` remains available for a manually created
tag or a release rerun.

The current baseline tag is `v0.1.0-dev.1`. Since tagpr uses the normal
SemVer patch bump by default, the first generated proposal after this baseline
will be `0.1.1`. If the next release should be the `0.1.0` stable release,
edit all three version files in the generated release pull request before
merging it; the release workflow requires the tag and all version files to
match exactly.


## Bounded full verification

Full verification accepts `VERIFY_FULL_SUITES=all` or a comma-separated suite
selection: `core`, `current-codegen`,
`compatibility-lifecycle`, `compatibility-graph`, and
`compatibility-mapping`. The scheduled and manually dispatched workflow runs one
suite per runner with `fail-fast: false`; any failed matrix job still fails
the workflow, and state transitions inside a fixture remain serial.

The common verification helper records suite, case, and command start/end
events, elapsed time, command, workspace, and log path. A timed-out command
returns status 124, records the log tail and process tree, and terminates the
whole process group. Failed temporary workspaces and logs are retained by
default; set `VERIFY_KEEP_TEMP_ON_FAILURE=0` to remove them.

Initial timeout defaults are 300 seconds per build, 180 seconds per pub get,
900 seconds for the frontend build, 1200 seconds per case, 1800 seconds per
suite, 3600 seconds for the full invocation, 1800 seconds for a watch process, and 300 seconds for watch polling.
Override them with `VERIFY_BUILD_TIMEOUT_SECONDS`,
`VERIFY_PUB_GET_TIMEOUT_SECONDS`,
`VERIFY_FRONTEND_BUILD_TIMEOUT_SECONDS`,
`VERIFY_CASE_TIMEOUT_SECONDS`, `VERIFY_SUITE_TIMEOUT_SECONDS`,
`VERIFY_FULL_TIMEOUT_SECONDS`, `VERIFY_WATCH_PROCESS_TIMEOUT_SECONDS`,
`VERIFY_WATCH_TIMEOUT_SECONDS`, `VERIFY_TIMEOUT_GRACE_SECONDS`.
