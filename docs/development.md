# Development

Use one Dart SDK, Rust toolchain, and pub cache for stock/native comparisons.
Repository scripts honor DART_BIN, CARGO_BIN, PUB_CACHE, RUSTUP_HOME, and
CARGO_HOME; each also falls back to the repository toolchain and then PATH.

## Supported toolchain

The release line supports Dart >=3.11.0 <4.0.0. CI checks a minimum solution
with Dart 3.11.0 and a current solution with Dart 3.13.3. The core package
window is:

| Package | Supported version |
| --- | --- |
| analyzer | >=13.3.0 <15.0.0 |
| build | >=4.0.9 <5.0.0 |
| build_config | >=1.3.2 <1.4.0 |
| build_runner | >=2.16.2 <2.17.0 |
| package_config | >=2.2.0 <4.0.0 |

The build_runner upper bound protects private worker interfaces. Its 2.16.2
release supports analyzer 14.5; the combined dependency constraints make
analyzer 14.3 the effective minimum. See
[configuration compatibility](configuration.md) for upstream behavior and
[ADR 0007](adr/0007-sdk-and-dependency-compatibility-window.md) for the policy.

## Try an unreleased checkout

Add this repository as a path dependency in the application. Build the
frontend in the checkout, then run it from the application:

```bash
# In this checkout:
dart pub get
cargo build --release --manifest-path rust/Cargo.toml

# In the application that depends on this checkout:
BUILD_RUNNER_ACCELERATOR_BIN="/path/to/checkout/rust/target/release/build_runner_accelerator" \
  dart run build_runner_accelerator build --mode rust
```

Strict rust mode makes unsupported source setups visible instead of silently
using stock build_runner.

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

The full level includes core, code generation, compatibility lifecycle,
compatibility graph, and compatibility mapping. VERIFY_FULL_SUITES accepts a
comma-separated subset for local runs or CI shards.

## Correctness and CI

Run the closest comparison script when changing a boundary:

| Change area | Focused check |
| --- | --- |
| Filter selection, graph, deletion, or watch | `BUILD_FILTER_CASE_GROUP=watch-source bash scripts/correctness_build_filter.sh` |
| Settings and config reload | `SETTINGS_CASE_GROUP=paths bash scripts/correctness_settings.sh` |
| CLI routing, fallback, or process signals | `bash scripts/correctness_cli.sh` |
| Watch lifecycle | `bash scripts/watch_smoke.sh` |
| Freezed/Riverpod compatibility | `scripts/correctness_freezed.sh`, `scripts/watch_smoke_freezed.sh`, `scripts/correctness_riverpod.sh`, `scripts/watch_smoke_riverpod.sh` |
| Manifest or builder output | The relevant fixture script; see the full verification groups. |

The CI workflow runs the same checks in functional groups:

| Group | Coverage |
| --- | --- |
| Core | Unit tests, format, Dart analysis, Rust checks, baseline comparisons |
| Selection | CLI and build-filter parsing, demand, fallback |
| Graph and lifecycle | Incremental state, deletion, failures, watch and configuration transitions |
| Builder compatibility | Stock comparisons for supported builders and mappings |
| Release | SDK bounds, package validation, signed artifact and platform checks |

CI splits long correctness suites into parallel jobs. Local full verification
keeps each selected suite's state transitions ordered in isolated workspaces.

## Benchmarks

Benchmarks are separate from correctness checks. Compare clean, no-op,
one-file, and broad incremental builds with the same SDK and cache; verify
output bytes. Keep metrics and traces out of timed runs.

| Goal | Entry point |
| --- | --- |
| Current launcher-inclusive summary | [benchmarks.md](benchmarks.md) |
| Build-filter and supported-builder comparisons | `scripts/benchmark_matrix.sh`; `BUILDERS=optional bash scripts/benchmark_matrix.sh` |
| Freezed/Riverpod fixture benchmarks | `scripts/benchmark_freezed.sh`, `scripts/benchmark_riverpod.sh` |
| Cold start or cache investigation | The harness and experiment links in [benchmarks.md](benchmarks.md) |
| Per-worker diagnostic trace | `BUILD_RUNNER_ACCELERATOR_METRICS=1` and, where needed, `BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE=1` |

Keep raw measurements local. Update the public benchmark summary only from a
reproducible launcher-inclusive run; document new research in a focused
benchmark note rather than this guide.

## Release checks

The release workflow builds the platform artifacts, verifies version/help,
and signs the manifest. The signing key is a CI secret; its public key is
pinned in the package. See the
[launcher and release contract](launcher-and-release.md) and [roadmap](roadmap.md)
for release targets and remaining gates.
