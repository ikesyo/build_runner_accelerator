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

The shared CLI contract cases live in `test/data/cli_contract.json`. Dart's
`cli_contract_test.dart` and Rust's `cli::tests::shared_cli_contract` consume the
same acceptance and settings expectations independently. The CLI comparison
script also uses the table for real-process rejection/help/version checks,
including exit status, unchanged workspace files, and no child Dart execution.
Keep diagnostic wording checks separate from these behavioral expectations.
The stock configuration comparisons remain the reference for build_runner
semantics; sharing test data does not couple either entrypoint's implementation.

Nested-package checks accept comma-separated `NESTED_PACKAGE_CASE_GROUP` values
(for example, `default-on,boundary`); unset runs every case. CI distributes these
cases across the existing build-filter parallel lanes using measured durations.

The CI workflow runs the same checks in functional groups:

| Group | Coverage |
| --- | --- |
| Core | Unit tests, format, Dart analysis, Rust checks, baseline comparisons |
| Selection | CLI and build-filter parsing, demand, unsupported requests |
| Graph and lifecycle | Incremental state, deletion, failures, watch and configuration transitions |
| Builder compatibility | Stock comparisons for supported builders and mappings |
| Release | SDK bounds, package validation, signed artifact and platform checks |

Watch logs and builder histories are stored outside watched workspaces, so test
bookkeeping cannot trigger or mask a rebuild.

`OUTPUT_POLICY_CASE_GROUP` selects `routing`, `modes`, `source`, `cache`,
`failure`, or `api` in the output-policy comparison script; the default runs all groups.

CI shares runner setup through parallel steps within a small number of jobs.
Local full verification keeps each selected suite's state transitions ordered
in isolated workspaces.

## SDK lifecycle comparison

The existing SDK/dependency jobs run both package analysis/tests and a real
worker comparison. These cover different boundaries: `build_runner --help`
does not initialize the native worker or resolve a Dart input library.

Run the same comparison locally with an installed SDK:

```bash
DART_BIN=/path/to/dart-3.11.0/bin/dart bash scripts/correctness_sdk.sh --resolution downgrade
DART_BIN=/path/to/dart-3.13.3/bin/dart bash scripts/correctness_sdk.sh --resolution upgrade
```

The minimal `fixtures/sdk_compat_app` uses an ordinary source builder and
`resolver.libraryFor`; it stages output before a deliberate builder failure.
It resolves dependencies once per SDK, then copies the resulting lockfile to
native and enforces it with Pub. Initial generation, no-op, input change,
deletion, rename, builder failure/recovery and two paired watch regenerations compare
complete generated file inventories and bytes. Failure asserts that native
outputs and the persisted graph remain unchanged. Stock is a separate process
in a separate workspace. Current-SDK fixtures keep their existing constraints.
The second watch edit exercises resolver invalidation in the resident worker.

The check prints the SDK, worker mode and resolved build_runner/analyzer/build
versions. Per-command logs, both ordinary `pubspec.lock` files and watch logs
are retained in the printed results directory (`--results PATH` selects a new
directory). Commands and watch waits have timeouts; CI uploads results on failure.
No dependency-version inventory is maintained separately from Pub's lockfiles.

On 2026-10-23, Linux x64 replays of both commands above passed every listed
case, including watch and native failure protection. The resolved versions are
available in the command logs/lockfiles; future upgrades are checked again in CI.

The SDK probe uses one non-AOT worker (`--force-jit`, SDK-specific kernel/script).
It does not test all compilation modes on every SDK. Packaged AOT/prewarm and
platform installation remain covered by [distribution E2E](distribution-validation.md);
forced kills and publication I/O faults remain in
`correctness_commit_recovery.sh`. Neither suite is duplicated in the SDK probe.

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

With `BUILD_RUNNER_ACCELERATOR_METRICS=1`, watch reports disk graph reloads
separately from `source=resident` ownership reuse. Ordinary build graph metrics
report zero load time for resident state; `graph_reuse` in wall tracing marks
that path. Watch cycle metrics include workspace/configuration preparation and
worker setup, report success or failure, and exclude event waiting and debounce.
A failed attempt discards tentative state and returns to the validated disk
loader; source post-process tracking borrows successful committed state. See
[ADR 0037](adr/0037-resident-watch-graph.md) for ownership and invalidation.
`BUILD_RUNNER_ACCELERATOR_WALL_TRACE=1` adds stage intervals; disable both metrics
and tracing for elapsed-time comparisons.

Keep raw measurements local. Update the public benchmark summary only from a
reproducible launcher-inclusive run; document new research in a focused
benchmark note rather than this guide.

## Release checks

The release workflow requires successful correctness CI for the exact source
commit, locked Cargo builds/tests, and packaged-artifact E2E in the existing
five target lanes. It verifies/installs all final signed archives and smoke-tests the host binary
before publication. Manual dispatch defaults to a non-publishing dry-run with a
temporary signing key. See [distribution validation](distribution-validation.md)
for verification order, replay commands, timing evidence, and platform limits.
The production public key remains pinned in the package.
