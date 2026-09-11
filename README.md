# build_runner_accelerator

`build_runner_accelerator` is an experimental Rust-accelerated frontend for
[`build_runner`](https://pub.dev/packages/build_runner). Rust owns filesystem
scanning, incremental planning, scheduling, and transactional output commits.
The Dart worker continues to run Dart builders and the Analyzer-backed
`BuildStep`, `AssetReader`, and `Resolver` APIs.

The project is in a pre-release stage. Compatibility with stock `build_runner`
is the primary constraint: when the native frontend is selected, supported
fixtures must produce byte-identical outputs and preserve incremental, failure,
delete, rename, and watch semantics.

## Installation

The first public release is the `0.1.0-dev.1` pre-release. Add it to the
target project's `dev_dependencies`:

```bash
dart pub add dev:build_runner_accelerator:^0.1.0-dev.1
```

Or add the dependency explicitly:

```yaml
dev_dependencies:
  build_runner_accelerator: ^0.1.0-dev.1
```

Run the project-local executable in the same place where you would normally
run `build_runner`:

```bash
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
```

The default `auto` mode downloads and verifies the matching signed native
frontend on supported Linux, macOS, and Windows platforms. On macOS Intel or
when native execution is unavailable, it falls back to stock Dart
`build_runner`. Use `--mode dart` to select the stock path explicitly, or
`--mode rust` to require the native frontend.

## Try from source

To try unreleased changes, check out this repository, add it to the target
project as a path dependency, and build the matching local Rust frontend:

```bash
git clone https://github.com/ikesyo/build_runner_accelerator.git
cd build_runner_accelerator
dart pub get
cargo build --release --manifest-path rust/Cargo.toml
```

Add the checkout to the target project's `pubspec.yaml`:

```yaml
dev_dependencies:
  build_runner_accelerator:
    path: /absolute/path/to/build_runner_accelerator
```

Then resolve the target project and run the launcher in strict native mode:

```bash
cd /absolute/path/to/your/project
dart pub get
cd /absolute/path/to/build_runner_accelerator
BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/release/build_runner_accelerator" \
  dart run bin/build_runner_accelerator.dart build \
  --root /absolute/path/to/your/project \
  --mode rust
```

The path dependency is required so the package's internal manifest generator and
worker are available from the target project's package configuration. Using
`--mode rust` makes an unsupported or incorrectly configured source setup fail
instead of silently falling back to stock `build_runner`. Use `watch` instead of
`build` for a native watch session. The launcher also supports `--mode dart`
when the stock path is preferred.

## Frontend modes

| Mode | Behavior |
| --- | --- |
| `auto` (default) | Use the native frontend when the binary and manifest subset are available; otherwise run stock Dart `build_runner`. |
| `rust` | Require the native frontend and a compatible manifest; return an error instead of falling back. |
| `dart` | Always run stock Dart `build_runner`. |

Useful launcher options are `--root`, `--dart`, `--jobs`,
`--interval-ms`, `--worker`, `--force-aot`, and `--force-jit`. The latter two
use the stock build_runner names and are honored by both native and Dart
frontends; they are mutually exclusive. Build-runner options that are not
consumed by the launcher are passed to the Dart path. The native frontend
accepts only its documented launcher options; use `--mode dart` when passing
arbitrary build-runner arguments. A preinstalled native binary can be selected
with `BUILD_RUNNER_ACCELERATOR_BIN`.

Worker AOT and launcher AOT are separate concerns. In the normal invocation
above, `dart run` starts the launcher as a Dart program; `--force-aot` and
`BUILD_RUNNER_ACCELERATOR_WORKER_AOT` control the generated Dart worker, not
the launcher itself. The package does not distribute an AOT-compiled launcher.
An advanced user may compile the launcher with `dart compile exe`; that form is
supported as a compatibility path for release-cache misses, but it is not the
normal installation or benchmark path.

## Architecture

| Component | Responsibility |
| --- | --- |
| Rust frontend | Workspace snapshot, dependency and glob tracking, action graph, dirty propagation, phase scheduling, overlay, atomic commit, and native watch. |
| Dart worker | Builder factories, `BuildStep`, `AssetReader`, Analyzer-backed resolver work, and builder-owned resource lifetimes. |
| Manifest generator | Resolves official `PackageGraph` and `BuildConfig` data into a workspace-specific worker manifest and generated worker entrypoint. |
| Launcher | Selects the frontend, manages the native artifact cache, verifies releases, and preserves a conservative Dart fallback. |

The main builder path is manifest-first. Builder names are not hard-coded into
the Rust planner. The generated manifest carries builder identity, target and
phase ordering, input/output mappings, `build_to`, required inputs, source
filters, and resolved options. Supported normal builders and the cache-only
post-process subset use the same action model.

Rust and Dart communicate through the versioned contract in
[`protocol/v1.md`](https://github.com/ikesyo/build_runner_accelerator/blob/main/protocol/v1.md). Control messages are length-prefixed JSON;
successful asset reads and build results use the required binary frames.
Standard output is reserved for IPC and diagnostics go to standard error.

## Distribution

The public package contains the Dart launcher, manifest generator, worker
runtime, and protocol implementation. Rust frontend executables are released
per platform rather than packed into the Dart package. This keeps the package
portable and allows the launcher to select a target-specific binary.

The initial release targets Linux x64, Linux arm64, macOS arm64, Windows x64,
and Windows arm64. macOS Intel is intentionally not a native release target
and uses the Dart fallback in `auto` mode.

The release matrix, cache locations, signature rules, and mirror override are
documented in [`docs/launcher-and-release.md`](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/launcher-and-release.md).
The launcher adds one process launch and local cache/target resolution, but it
does not proxy worker IPC or participate in action scheduling. Worker AOT
artifacts remain workspace-local and are invalidated by the SDK, package
configuration, or worker dependency changes. For startup benchmarks or
offline use, run a preinstalled binary through
`BUILD_RUNNER_ACCELERATOR_BIN`.

The launcher keeps archive extraction, signature verification, and release
download dependencies out of its normal startup path. A valid user-cache hit
is checked with lightweight metadata and executable hashing; the heavier
release downloader is started only when the cache needs to be filled or
repaired.

## Current compatibility and limitations

The 0.1.x package line supports Dart `>=3.11.0 <4.0.0`. The core build stack
is intentionally bounded to the versions exercised by CI:

| Dependency | Supported range |
| --- | --- |
| `analyzer` | `>=13.3.0 <15.0.0` |
| `build` | `>=4.0.9 <5.0.0` |
| `build_config` | `>=1.3.2 <1.4.0` |
| `build_runner` | `>=2.16.1 <2.17.0` |
| `package_config` | `>=2.2.0 <4.0.0` |

The release workflow checks both the minimum dependency solution and the current solution. Older
Dart SDKs and `build_runner` versions are not supported by this release line;
the worker uses private `build_runner` interfaces whose signatures are not
stable across those versions.

The native frontend has been validated against workspace fixtures using
`json_serializable`, `freezed`, `built_value`, `riverpod_generator`, and a small
arbitrary builder. The fixture set is evidence for compatibility, not a
built-in catalog: the generic manifest path remains the source of truth.

The following are deliberately outside the first release baseline:

- complete `build.yaml` and `build_runner` semantic compatibility;
- unsupported manifest shapes, optional builders, and external-process
  builders;
- exact resolver dependency selection for every conditional import/export;
- automatic worker-count selection;
- chunking of a single build-result frame larger than the protocol limit;
- compatibility with build-runner's private `AssetGraph` binary format.

Unsupported configurations must remain on the conservative Dart fallback in
`auto` mode. See [`docs/roadmap.md`](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/roadmap.md) for release gates and
post-release work.

## Development

Contributor setup, local SDK selection, correctness checks, and benchmark
commands are in [`docs/development.md`](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/development.md). The latest launcher-inclusive measurements are in [`docs/benchmarks.md`](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/benchmarks.md).
Historical implementation experiments are in [`docs/benchmarks/experiments-2026-09.md`](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/benchmarks/experiments-2026-09.md).

Architecture decisions are summarized in [`docs/adr/README.md`](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/adr/README.md).
