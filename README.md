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

The current package version is `0.7.0`. Add it to the
target project's `dev_dependencies`:

```bash
dart pub add dev:build_runner_accelerator:^0.7.0
```

Or add the dependency explicitly:

```yaml
dev_dependencies:
  build_runner_accelerator: ^0.7.0
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
| Manifest generator | Resolves the package graph and official `BuildConfig` data into a workspace-specific worker manifest and generated worker entrypoint. |
| Launcher | Selects the frontend, manages the native artifact cache, verifies releases, and preserves a conservative Dart fallback. |

The main builder path is manifest-first. Builder names are not hard-coded into
the Rust planner. The generated manifest carries builder identity, target and
phase ordering, input/output mappings, `build_to`, required inputs, source
filters, and resolved options. Supported normal builders and the supported
post-process subset use the same action model, including source and cache
outputs.

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
artifacts live under the workspace's `aot-sdk` directory and are invalidated
by the SDK, package configuration, or worker dependency changes; compiled
artifacts are additionally cached machine-wide (see
[Performance and caching](#performance-and-caching)). For startup
benchmarks or offline use, run a preinstalled binary through
`BUILD_RUNNER_ACCELERATOR_BIN`.

The launcher keeps archive extraction, signature verification, and release
download dependencies out of its normal startup path. A valid user-cache hit
is checked with lightweight metadata and executable hashing; the heavier
release downloader is started only when the cache needs to be filled or
repaired.

## Performance and caching

The accelerator keeps four shared caches under a machine-wide cache root
so repeated builds — including builds in fresh checkouts on the same
machine — skip the expensive cold paths:

- `<cache>/byte_store/<fingerprint>` — the analyzer byte store shared by all
  workers. The fingerprint covers the SDK summary and analyzer-relevant
  configuration, so resolved entries are reused across workers, workspaces,
  checkouts, and phase resets within a build.
- `<cache>/worker-aot/<fnv1a64(cache-key)>` — compiled worker AOT artifacts.
  The cache key is content-derived (SDK, worker source, manifest, lockfile,
  and package-config identity); a shared artifact is validated against the
  current workspace's dependency digests before it is restored into the
  workspace-local `aot-sdk` directory.
- `<cache>/probe/<builder-manifest-fingerprint>-<impl>.json` — the
  builder-factory probe results from manifest generation. The fingerprint
  covers the lockfile and every package's `build.yaml`, and `<impl>` digests
  the Dart SDK version plus the probed packages' transitive dependency
  closure (versioned pub-cache directories, or source digests for path
  dependencies; the workspace's own packages also contribute their
  dev_dependencies and overrides), so a factory edit invalidates the entry.
  Only complete
  responses are cached, so a cache hit skips the probe subprocess entirely.
- `<cache>/manifest-kernel/<key>` — the manifest generator's compiled kernel.
  The key includes SDK and package configuration identities; each hit checks
  the compiled source dependencies and artifact contents. Workspace build.yaml
  inputs are read again on every manifest regeneration. Reuse requires the
  same absolute package roots; the first compile still costs source startup
  plus snapshot serialization. See [ADR 0015](docs/adr/0015-manifest-generator-kernel-cache.md).

On a generator snapshot miss, synchronous worker AOT starts from a lightweight
catalog helper before the full generator compiles. Both generators share the
existing Dart configuration loader and builder selector. The full generator
validates the manifest; a different final worker discards the early AOT.
Snapshot hits skip the helper. Set `BUILD_RUNNER_ACCELERATOR_EARLY_CATALOG=0`
to disable this earlier selection pass and compiled-worker probing. On a probe
cache miss, the generator can reuse the compiled worker in a separate factory
probe process, avoiding a second compilation of the builder imports. A source
mismatch, unavailable artifact or failed probe uses the source probe.
See [ADR 0016](docs/adr/0016-early-worker-catalog.md).

The cache root resolves `BUILD_RUNNER_ACCELERATOR_CACHE` first — a relative
path is anchored at the workspace root — then the platform cache directory
(`%LOCALAPPDATA%` on Windows, `~/Library/Caches` on macOS,
`$XDG_CACHE_HOME` or `~/.cache` elsewhere) plus
`build_runner_accelerator`. Caching that directory in CI gives every build
warm-start behavior. Where the caches are cold, the first build still pays the
synchronous worker AOT compile and the first-touch analysis once per toolchain;
running `aot-prewarm` ahead of the next build performs the compile and
concurrently warms the byte store with JIT analysis shards. When the
builder manifest has to be (re)generated, the worker AOT compile overlaps
the manifest's factory probe rather than serializing after it.

`--jobs` defaults to the machine's logical CPU count, capped by the
available memory on Linux and macOS (`MemAvailable`, or `vm_stat`'s
free/inactive/speculative pages — ~1 GB per worker: each worker process
carries a full analyzer instance, and memory peaks when the byte store is
first filled). Pass an explicit `--jobs` to override the default in either
direction.

Byte-store entries are content-addressed and safe to share across workers,
but stale fingerprint directories are not garbage-collected yet — reclaim
space by deleting directories for toolchains you no longer use, or prune
the whole store (`rm -rf ~/.cache/build_runner_accelerator/byte_store`;
adjust the root for your platform or `BUILD_RUNNER_ACCELERATOR_CACHE`).

| Variable | Effect |
| --- | --- |
| `BUILD_RUNNER_ACCELERATOR_CACHE` | Relocate or isolate all machine-wide caches. |
| `BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT=0` | Run the manifest generator from source instead of its cached kernel. |
| `BUILD_RUNNER_ACCELERATOR_BYTE_STORE=0` | Disable the shared analyzer byte store. |
| `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM=0` | Disable the analysis shards spawned by `aot-prewarm`. |
| `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_JOBS=<n>` | Override the prewarm shard count (default: half of available CPUs). |
| `BUILD_RUNNER_ACCELERATOR_COMPILE_PREWARM=1` | Opt-in: overlap the synchronous worker AOT compile with JIT analysis shards that start filling the byte store (useful on slower machines where the compile window is long). |
| `BUILD_RUNNER_ACCELERATOR_MANIFEST_PREWARM=1` | Opt-in: also run the analysis shards across the whole manifest-generation window (kernel compile, early catalog, AOT compile, probe); killed before workers spawn. Off by default — the kernel-compile segment does not pay (ADR 0017). |
| `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_DIRS=lib` | Restrict the directories the prewarm shards resolve (comma-separated; `none` warms only the SDK summary). |
| `BUILD_RUNNER_ACCELERATOR_SDK_SUMMARY_PREWARM=0` | Opt out of the automatic single summary-only shard spawned while the worker AOT compiles when the workspace has no SDK summary yet (≥4 CPUs only; ADR 0017). |
| `BUILD_RUNNER_ACCELERATOR_PART_FILTER=0` | Disable the `part` directive pre-filter that skips part-family actions whose input cannot produce output. |
| `BUILD_RUNNER_ACCELERATOR_WORKER_AOT` | `1`/`auto` (default for `build`) compiles the worker synchronously; `background` compiles in the background and keeps kernel workers running meanwhile (default for `watch`); `force` compiles synchronously with no kernel fallback; any other value keeps script workers. |

Design details are recorded in [ADRs 0009–0013](docs/adr/README.md).

## Current compatibility and limitations

The 0.2.x package line supports Dart `>=3.11.0 <4.0.0`. The core build stack
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
`json_serializable`, `freezed`, `built_value`, `riverpod_generator`, a small
arbitrary builder, and the isolated `drift_dev:analyzer` + `drift_dev:modular`
subset, as well as
demand-driven `is_optional` builders and ordinary Builders using
`build_extensions: {"": [...]}`. The latter follows pinned build_runner's
official all-asset semantics, including extensionless inputs, regular mapping
union, target/`generate_for` filtering, and source/cache visibility. The
tracked fixtures are pinned to the
`build_runner 2.16.1` compatibility window:

| Fixture | Generator versions |
| --- | --- |
| `fixtures/freezed_app` | `freezed 4.0.1`, `json_serializable 6.14.1` |
| `fixtures/riverpod_app` | `riverpod_generator 4.0.9`, `freezed 4.0.1`, `json_serializable 6.14.1` |
| `fixtures/drift_analyzer_app` | `drift 2.34.4`, `drift_dev 2.34.6` (analyzer → modular subset) |

These fixtures are compared with stock `build_runner` for their respective
clean, no-op, incremental, failure, deletion, rename, and watch cases. The
fixture set is evidence for compatibility, not a built-in catalog: the generic
manifest path remains the source of truth.

The following are deliberately outside the first release baseline:

- complete `build.yaml` and `build_runner` semantic compatibility;
- complete Drift workspace support, including `not_shared`, full
  `driftCleanup`, `registry_builder`, and
  `build_web_compilers`;
- unsupported manifest shapes and external-process builders;
- optional-builder shapes that require semantics beyond the supported
  demand-driven read/find-assets path;
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
