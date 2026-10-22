# FVM real-project probe

Pinned source: [btwld/fvm@6f4c0a2528ef2a293e5f84d216a37be30411b3a5](https://github.com/btwld/fvm/tree/6f4c0a2528ef2a293e5f84d216a37be30411b3a5),
version 4.3.2. The root is a Dart CLI package, with SDK `>=3.6.0 <4.0.0`,
no Flutter SDK dependency, and no workspace resolution. Nested projects are
present but are not workspace members. Only root-package code generation is
under test. Upstream's MIT license (Copyright 2019 Leo Farias) is retained in
each checkout; this probe does not vendor its source. Upstream AGENTS.md and
release workflows prescribe `dart run build_runner build` (older workflows
also pass `--delete-conflicting-outputs`, ignored by stock 2.16.2).

## Resolution and builder contract

The upstream lock exists. Dart 3.13.3 `pub get` succeeded without changing its
bytes. It pins build_runner 2.4.15, build 2.4.2, Analyzer 7.3.0,
dart_mappable_builder/dart_mappable 4.5.0 and build_version 2.1.1. On this SDK,
that old stock command reported successful generation (57 outputs including
private artifacts, 165 actions) and warned that Analyzer supports language
3.8 while the SDK is 3.13. The process remained alive after its success log;
it was interrupted after more than six minutes with exit 130. This is not a
successful command-exit result or a native compatibility claim for that lock.

Adding only the accelerator as a path dev dependency resolves successfully
under the original FVM constraints, without overrides. It necessarily selects
the native supported build_runner window. The complete 27-package change set
is in [dependency-changes.md](dependency-changes.md); the full introduced
solution is [pubspec.lock](pubspec.lock). It includes build_runner 2.16.2,
build 4.0.11, build_config 1.3.3, Analyzer 14.6.0,
dart_mappable_builder/dart_mappable 4.10.0 and build_version 2.2.1. The solver
also updates production dart_mappable and meta within their existing
constraints. These resolution changes are part of the adoption cost; they
are not changes to the application's dependency declarations.

The lock's effective SDK range also changes from `>=3.6.0 <4.0.0` to
`>=3.13.0 <4.0.0`: selected Analyzer 14.6.0 and _fe_analyzer_shared 110.0.0
each declare `sdk: ^3.13.0`. FVM's root SDK declaration is unchanged. This
recorded solution was tested only on Dart 3.13.3, including both frontends;
do not use the accelerator package's wider SDK range as evidence that this
exact FVM lock works on earlier SDKs.

The paired comparison uses this **same introduced solution in both trees**,
not the upstream old lock for stock versus a new lock for native.

Published build.yaml and factory implementations establish:

| Application | Configured native phase | Inputs | Declared outputs | Behavior |
| --- | --- | --- | --- | --- |
| dart_mappable_builder:dart_mappable_builder | 1 | `.dart`, root `generate_for: [lib/**]` | `.mapper.dart`, `.init.dart`, source | Analyzer resolver reads; required `.freezed.dart` ordering; no initializer configured |
| build_version:build_version | 2 | suffix `pubspec.yaml` | literal `lib/src/version.dart`, source | Reads root pubspec version; skips nested pubspec primary IDs |

Stock uses phases 0 then 1 in the same application order; numeric phase IDs
are not compared as equal. dart_mappable sees 73 inputs and emits
12 mapper files; build_version sees four matching pubspec inputs but emits
only the root version. source_gen combining/cleanup factories are available
in the catalog but have no active application in the generated native manifest.
Catalog presence is not evidence that a builder ran. The builders use Dart
BuildStep/resolver/formatter APIs and do not launch Flutter or other external
tools. Stock and native infrastructure compile their Dart workers with the
same Dart SDK. No Flutter SDK was installed.

## Reproduce

Run from the accelerator checkout after provisioning Dart 3.13.3 and Rust
1.98.1. The explicit setup below assumes the managed environment's installed
SDK/toolchain layout under `.toolchains`; point `DART_SDK`, `RUSTUP_HOME`,
`CARGO_HOME` and `CARGO_BIN` to your installations if they live elsewhere.
`DART_BIN` uses the SDK-local `bin/dart-cloud` wrapper in this managed
environment. For a non-managed SDK without that wrapper, also set
`DART_BIN="$DART_SDK/bin/dart"` after selecting `DART_SDK`, before running any
pub or probe commands. Both frontends must use the same SDK/cache. These exports work
without an ignored `.toolchains/task-env.sh` file. Cargo jobs are 2. The SDK
wrapper removes HOME; the replay also removes HOME from the whole environment
so subprocesses inherit it. Logs remain outside watched trees.
No `/tmp` environment configuration file is used. Networked pub get needs
pub.dev package metadata, archives, and its advisories API.

```bash
export DART_SDK="$PWD/.toolchains/dart/dart-sdk"
export DART_BIN="$DART_SDK/bin/dart-cloud"
# For a non-managed SDK without dart-cloud, override the preceding line:
# export DART_BIN="$DART_SDK/bin/dart"
export PUB_CACHE="$PWD/.pub-cache"
export RUSTUP_HOME="$PWD/.toolchains/rustup"
export CARGO_HOME="$PWD/.toolchains/cargo"
export CARGO_BIN="$RUSTUP_HOME/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/cargo"
export PATH="$(dirname -- "$CARGO_BIN"):$DART_SDK/bin:$PATH"
export CARGO_BUILD_JOBS=2
export XDG_CONFIG_HOME="$PWD/.toolchains/analytics-config"
export DART_SUPPRESS_ANALYTICS=true
export BUILD_MAX_WORKERS_PER_TASK=1
export BUILD_RUNNER_ACCELERATOR_CACHE="$PWD/.toolchains/accelerator-cache"
export BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/release/build_runner_accelerator"
"$CARGO_BIN" build --locked --release --manifest-path rust/Cargo.toml -j 2

git clone https://github.com/btwld/fvm.git /workspace/fvm-source
git -C /workspace/fvm-source checkout --detach 6f4c0a2528ef2a293e5f84d216a37be30411b3a5
(cd /workspace/fvm-source && "$DART_BIN" pub get --enforce-lockfile)
git -C /workspace/fvm-source diff --exit-code -- pubspec.lock
git -C /workspace/fvm-source worktree add --detach /workspace/fvm-stock 6f4c0a2528ef2a293e5f84d216a37be30411b3a5
git -C /workspace/fvm-source worktree add --detach /workspace/fvm-native 6f4c0a2528ef2a293e5f84d216a37be30411b3a5
```

Prepare both worktrees with exactly one added dev dependency and the recorded
solution. The saved lock's path is the observed `/workspace/build_runner_accelerator`;
rewrite only that local path if the checkout lives elsewhere:

```bash
python3 - <<'PY'
from pathlib import Path
repo = Path.cwd()
lock = (repo / 'docs/probes/fvm/pubspec.lock').read_text()
lock = lock.replace('/workspace/build_runner_accelerator', str(repo))
for directory in ['/workspace/fvm-stock', '/workspace/fvm-native']:
    root = Path(directory)
    spec = root / 'pubspec.yaml'
    text = spec.read_text().replace('dev_dependencies:\n',
        f'dev_dependencies:\n  build_runner_accelerator:\n    path: {repo}\n')
    spec.write_text(text)
    (root / 'pubspec.lock').write_text(lock)
PY
(cd /workspace/fvm-stock && "$DART_BIN" pub get --enforce-lockfile)
(cd /workspace/fvm-native && "$DART_BIN" pub get --enforce-lockfile)
PYTHONDONTWRITEBYTECODE=1 python3 scripts/probe_fvm.py \
  /workspace/fvm-stock /workspace/fvm-native /workspace/fvm-evidence
```

The replay runs stock first and then native (`--jobs 1`), initial build, no-op,
an enum model edit (`Level.probe` in `lib/src/models/log_level_model.dart`),
and short paired watch. Watch starts sequentially, reverts the edit, then
replays that same edit. Every completed checkpoint compares all current
published output IDs from both private graphs and their raw bytes, plus the
entire physical root `lib` tree to detect extra files. It asserts 13 source
outputs, no native cache outputs, no-op stability, actual mapper changes, and
watch convergence to the same initial/edited bytes. No byte normalization is
performed. The private graph readers are pinned to stock schema 47/native
payload 6 and fail if those change. `report.json` records complete output
paths, sizes, SHA-256 and build command results; phase logs retain diagnostics.

## Findings and validation

Before the fix, native manifest generation failed explicitly on build_version's
runtime mapping before actions. The shared converter admitted dot extensions,
captures, anchored paths and virtual tokens but rejected an ordinary filename
suffix. It now preserves literal filename/path suffixes and output fragments,
without anchoring them or adding a dot. Rust already supports this action shape.
No package-name production branches, constraint changes, timeout relaxation,
or graph/phase visibility changes were needed. ADR 0004 records the decision.

The existing multi-mapping regression now covers root and prefixed/nested
`schema.yaml` suffix replacement, runtime options, no-op, change, native
failure preserving committed output and graph, recovery, and output removal
after primary deletion. It ran successfully with jobs 1. It reuses an existing
CI lane; the full FVM replay is manual rather than a new external-project CI job.
The added failure/recovery/delete commands took 0/1/1/1/0 seconds respectively
in the local instrumented mapping run (whole-second command logging), reusing
its existing worker compilations. This small regression cost and the shared
mapping contract justify retaining those checks in the existing lane.

On 2026-10-22 the fresh FVM replay passed all six checkpoints: initial, no-op,
model change, watch initial, watch revert, and watch reapply. All 13 current
public files matched by complete set and raw bytes at every checkpoint; the
mapper change and exact watch round trip were asserted. Initial and changed
inventories are retained in [output-digests.json](output-digests.json).
Both frontends returned zero for each build; native no-op reported no work and
stock no-op wrote zero outputs. The optional replay took about 100 seconds
including fresh worker compilation, builds, and watch on the two-core managed
environment; this is an observation for deciding CI cost, not a speedup claim.

Local verification on the same Dart 3.13.3 / Rust 1.98.1 toolchains:

| Command / check | Result |
| --- | --- |
| `dart test test/manifest_mapping_test.dart` | 11 passed |
| `MULTI_MAPPING_JOBS=1 bash scripts/correctness_multi_mapping_builder.sh` | Passed, including literal suffix failure/recovery/deletion |
| `bash scripts/verify.sh` | Passed after an initial formatting failure was corrected |
| `VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh` | Passed, including the arbitrary-only tail; 654 seconds |
| `VERIFY_LEVEL=full VERIFY_FULL_SUITES=compatibility-mapping bash scripts/verify.sh` | Passed; 1531 seconds; mapping, compiler, registry, empty-input and Drift build/watch cases |
| `bash scripts/watch_smoke.sh` | Passed; generated-output deletion, source edit and conditional dependency edit |

Both mandatory quick commands were executed in this task; no result was reused
from #127/#128. Rust tests within quick passed 155 tests with one ignored;
Dart analysis and formatting passed. The full command above selects the related
mapping group, not every local full suite. It reuses the existing compiler
fixtures without adding DDC modes. CI [817](https://github.com/ikesyo/build_runner_accelerator/actions/runs/39719177196)
at 1044c09 passed overall, including Rust clippy and Dart tests/SDK checks.
Final-head CI and review status are tracked in [PR 129](https://github.com/ikesyo/build_runner_accelerator/pull/129).

This is a compatibility probe, not a performance benchmark. The result does
not cover other FVM commits, upstream's old lock on native, other dependency
solutions/SDKs, nested projects, FVM runtime commands/integration tests requiring
Flutter, all dart_mappable options or workspace-wide compatibility.
