# Development

Use one Dart SDK, Rust toolchain, and pub cache for stock/native comparisons.
Repository scripts honor DART_BIN, CARGO_BIN, PUB_CACHE, RUSTUP_HOME, and
CARGO_HOME; each also falls back to the repository toolchain and then PATH.

## Supported toolchain

Supported SDK/dependency ranges and the resolver backport are documented in
[the compatibility contract](launcher-and-release.md#supported-dependencies).
CI checks Dart 3.11.0/minimum and Dart 3.13.3/current resolutions; use the same
SDK and dependency solution for each stock/native comparison.

The worker imports private build_runner bootstrap, build-state and resolver
interfaces, and analyzer resolver, scanner and byte-store interfaces. Dependency
resolution and launcher compilation alone do not validate this boundary; the
SDK lifecycle check below compiles and executes the generated worker too.

## Try an unreleased checkout

Add this repository as a path dependency in the application. Build the
frontend in the checkout, then run it from the application:

```bash
# In this checkout:
dart pub get
cargo build --release --manifest-path rust/Cargo.toml

# In the application that depends on this checkout:
BUILD_RUNNER_ACCELERATOR_BIN="/path/to/checkout/rust/target/release/build_runner_accelerator" \
  dart run build_runner_accelerator build
```

Unsupported source setups fail explicitly. Use stock build_runner directly
when its wider feature set is needed.

## Local checks

After pub get, run formatting, analysis, tests, and Rust checks:

```bash
dart format --output=none --set-exit-if-changed lib bin test tool
dart analyze --fatal-infos lib bin test tool
dart test
cargo fmt --all --manifest-path rust/Cargo.toml -- --check
cargo clippy --locked --manifest-path rust/Cargo.toml --all-targets --all-features -- -D warnings
cargo test --locked --manifest-path rust/Cargo.toml
```

The common verification wrapper builds once and reuses the frontend:

```bash
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
VERIFY_LEVEL=full bash scripts/verify.sh
VERIFY_LEVEL=full VERIFY_FULL_SUITES=compatibility-graph bash scripts/verify.sh
git diff --check
```

The full level includes output policies, core, code generation, compatibility lifecycle,
compatibility graph, and compatibility mapping. VERIFY_FULL_SUITES accepts a
comma-separated subset for local runs or CI shards.

## Correctness and CI

Run the closest comparison script when changing a boundary:

| Change area | Focused check |
| --- | --- |
| Filter selection, graph, deletion, or watch | `BUILD_FILTER_CASE_GROUP=watch-source bash scripts/correctness_build_filter.sh` |
| Settings and config reload | `SETTINGS_CASE_GROUP=paths bash scripts/correctness_settings.sh` |
| Output verification, retention, or policy routing | `bash scripts/correctness_output_policies.sh` |
| CLI rejection, migration, or process signals | `bash scripts/correctness_cli.sh` |
| Optional producer and post-process demand | `scripts/correctness_optional_cleanup.sh`, `scripts/watch_smoke_optional_cleanup.sh`; see the [fixture guide](../fixtures/optional_cleanup_app/README.md) |
| Interrupted publication and recovery | `bash scripts/correctness_commit_recovery.sh` (test-only native adapter, forced process kill, stock equality and no-op) |
| Watch lifecycle | `bash scripts/watch_smoke.sh` |
| Freezed/Riverpod compatibility | `scripts/correctness_freezed.sh`, `scripts/watch_smoke_freezed.sh`, `scripts/correctness_riverpod.sh`, `scripts/watch_smoke_riverpod.sh` |
| Drift analyzer, modular, not_shared, and cleanup | `scripts/correctness_drift_analyzer.sh`, `scripts/watch_smoke_drift_analyzer.sh`, `scripts/correctness_drift_not_shared.sh`, `scripts/watch_smoke_drift_not_shared.sh` |
| Conduit registry dependency boundary and older stock contract | `scripts/correctness_registry_builder.sh`; [stock-only fixture and native blocker](../fixtures/registry_builder_app/README.md) |
| Conduit registry with a fixture-only Analyzer override | `scripts/correctness_registry_override.sh`, `scripts/watch_smoke_registry_override.sh`; [exact configuration and limits](../fixtures/registry_builder_override_app/README.md) |
| Published dart2js compiler chain | `scripts/correctness_web_compilers.sh`, `scripts/watch_smoke_web_compilers.sh`; [versions, raw-byte boundary and configuration](../fixtures/build_web_compilers_app/README.md) |
| Published DDC compiler chain, hot reload disabled | `scripts/correctness_web_compilers_ddc.sh`, `scripts/watch_smoke_web_compilers_ddc.sh`; [artifact contract and configuration](../fixtures/build_web_compilers_ddc_app/README.md) |
| Nested path packages and source visibility | `bash scripts/correctness_nested_packages.sh` |
| Manifest or builder output | The relevant fixture script; see the full verification groups. |
| Literal filename suffix mapping and real Dart CLI adoption | `scripts/correctness_multi_mapping_builder.sh`; optional [pinned FVM replay](probes/fvm/README.md) |

The shared CLI cases in `test/data/cli_contract.json` are consumed independently
by Dart and Rust tests and the real-process CLI comparison. Keep wording tests
separate from behavioral expectations. CI configuration is maintained in
[ci.yml](../.github/workflows/ci.yml); prefer parallel steps within existing jobs.
Watch logs and builder histories must stay outside watched workspaces.

## SDK lifecycle comparison

The existing SDK/dependency jobs run both package analysis/tests and a real
worker comparison. These cover different boundaries: `build_runner --help`
does not initialize the native worker or resolve a Dart input library.

Run the same comparison locally with an installed SDK:

```bash
DART_BIN=/path/to/dart-3.11.0/bin/dart bash scripts/correctness_sdk.sh --resolution downgrade
DART_BIN=/path/to/dart-3.13.3/bin/dart bash scripts/correctness_sdk.sh --resolution upgrade
DART_BIN=/path/to/dart-3.13.3/bin/dart bash scripts/correctness_sdk.sh --resolution upgrade --runner 2.17.1 --worker-mode aot
```

`fixtures/sdk_compat_app` exercises a Resolver-based builder with one non-AOT
worker. It compares file inventories and bytes for initial/no-op builds,
changes, deletion, rename, failure/recovery and two paired watch edits. Native
failure must preserve outputs and graph. Stock uses a separate workspace with
the same resolved lockfile. Both SDK replays passed locally on Linux x64 on
2026-10-23; CI repeats them on dependency updates.

Logs and lockfiles are retained in the printed results directory (`--results
PATH` selects one). This check does not cover all worker modes or platform/SDK
combinations. Packaged AOT/prewarm belongs to
[distribution E2E](distribution-validation.md); publication faults belong to
`correctness_commit_recovery.sh`.

## Benchmarks

Benchmarks are separate from correctness checks. Compare clean, no-op,
one-file, and broad incremental builds with the same SDK and cache; verify
output bytes. Keep metrics and traces out of timed runs.

| Goal | Entry point |
| --- | --- |
| Current launcher-inclusive comparison and user-reported examples | [benchmarks.md](benchmarks.md) |
| Build-filter and supported-builder comparisons | `scripts/benchmark_matrix.sh`; `BUILDERS=optional bash scripts/benchmark_matrix.sh` |
| Freezed/Riverpod fixture benchmarks | `scripts/benchmark_freezed.sh`, `scripts/benchmark_riverpod.sh` |
| Cold start or cache investigation | Historical implementation measurements in `docs/benchmarks/`; design decisions in [ADRs](adr/README.md) |
| Per-worker diagnostic trace | `BUILD_RUNNER_ACCELERATOR_METRICS=1` and, where needed, `BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE=1` |

Metrics distinguish disk graph loading from resident watch reuse; see
[ADR 0037](adr/0037-resident-watch-graph.md). `WALL_TRACE` is independent of
worker metrics. Disable metrics and tracing for elapsed-time comparisons.
Keep diagnostic runs separate from timed runs. The public benchmark guide
consolidates reproducible launcher-inclusive measurements and a separate
section of user-reported examples with their conditions and evidence limits.
The current mixed-application results were measured in PR #138.

## Release checks

The release workflow requires successful correctness CI for the exact source
commit, locked Cargo builds/tests, and packaged-artifact E2E in the existing
five target lanes. It verifies/installs all final signed archives and smoke-tests the host binary
before publication. Manual dispatch defaults to a non-publishing dry-run with a
temporary signing key. See [distribution validation](distribution-validation.md)
for verification order, replay commands, timing evidence, and platform limits.
The production public key remains pinned in the package.
