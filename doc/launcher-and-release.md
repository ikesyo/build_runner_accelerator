# Launcher and release contract

`build_runner_accelerator` is the single project-facing Dart package. It
contains the launcher, manifest generator, worker runtime, and protocol
libraries so the generated worker and native frontend share one versioned
contract.

## Invocation

Add the package to a target project's `dev_dependencies`:

```yaml
dev_dependencies:
  build_runner_accelerator: ^0.1.0
```

Invoke the project-local executable:

```bash
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
```

The launcher consumes `--mode`, `--root`, `--dart`, `--force-aot`, and
`--force-jit`. Native frontend options such as `--jobs`, `--interval-ms`, and
`--worker` are passed to the native frontend. The compile-mode options use the
stock build_runner names, are mutually exclusive, and are retained when the
stock Dart path is selected. Other arguments are retained for the stock Dart
path.
The native frontend does not consume arbitrary build-runner flags; use
`--mode dart` when those flags are required.

Mode behavior is part of the release contract:

| Mode | Native frontend unavailable | Unsupported manifest |
| --- | --- | --- |
| `auto` | Report on stderr, then run stock Dart `build_runner`. | Report on stderr, then run stock Dart `build_runner`. |
| `rust` | Return an error. | Return an error. |
| `dart` | Always run stock Dart `build_runner`. | Always run stock Dart `build_runner`. |

The launcher keeps the selected build process's standard streams intact. Its
own diagnostics are written to standard error.

When a native frontend is selected, the launcher enables the workspace-local
worker AOT cache unless `BUILD_RUNNER_ACCELERATOR_WORKER_AOT` is already set.
This makes dirty builds use the fast AOT worker after the first cache build.
Set the variable to `0` to keep the kernel/script worker path, or to
`background` when an asynchronous prewarm is preferred. Explicit
`--force-aot` and `--force-jit` take precedence over the environment variable;
`--force-aot` also makes an AOT compilation failure fatal, matching stock
build_runner's force semantics.

## Frontend resolution

Resolution is version-pinned and ordered:

1. `BUILD_RUNNER_ACCELERATOR_BIN`;
2. a workspace binary under
   `.dart_tool/build_runner_accelerator/bin/`;
3. the versioned user cache;
4. the matching GitHub Release artifact;
5. the Dart fallback in `auto` mode.

On a cache miss, the launcher downloads the versioned manifest and detached
Ed25519 signature, verifies the signature with the public key shipped in the
Dart package, validates the target, package version, and protocol major, then
downloads the matching archive. The archive size and SHA-256 are checked before
the executable is extracted or run. No unverified network binary is executed.

Installation uses temporary files, atomic renames, and a per-version/per-target
lock. Existing cache entries are re-hashed before execution; an incomplete or
modified entry is treated as a cache miss. The
`BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL` environment variable may point to
an HTTPS-compatible mirror. `BUILD_RUNNER_ACCELERATOR_CACHE` overrides the
local frontend cache root.

The frontend cache is separate from workspace-generated state:

```text
Linux:   $XDG_CACHE_HOME/build_runner_accelerator/<version>/<target>/
         or ~/.cache/build_runner_accelerator/<version>/<target>/
macOS:   ~/Library/Caches/build_runner_accelerator/<version>/<target>/
Windows: %LOCALAPPDATA%\build_runner_accelerator\<version>\<target>\
```

The workspace manifest, generated worker, graph, SDK facade, and AOT cache
remain under `.dart_tool/build_runner_accelerator/`. They are not part of a
portable frontend archive.

## Artifact matrix

Each release is built as five independent native cells:

| Target ID | Rust target | Archive | Runner |
| --- | --- | --- | --- |
| `macos-arm64` | `aarch64-apple-darwin` | `.tar.gz` | `macos-14` |
| `linux-x64` | `x86_64-unknown-linux-gnu` | `.tar.gz` | `ubuntu-24.04` |
| `linux-arm64` | `aarch64-unknown-linux-gnu` | `.tar.gz` | `ubuntu-24.04-arm` |
| `windows-x64` | `x86_64-pc-windows-msvc` | `.zip` | `windows-2022` |
| `windows-arm64` | `aarch64-pc-windows-msvc` | `.zip` | `windows-11-arm` |

macOS Intel is intentionally not a release target; in `auto` mode the launcher
falls back to stock Dart `build_runner` on that platform.

Archives contain the native executable, `VERSION`, and release notice files.
The publish job emits `release-manifest.json`, `SHA256SUMS`, and detached
Ed25519 signatures. The signed manifest records package version, protocol
major, target, filename, byte size, and SHA-256.

## Launcher overhead

The launcher adds one Dart process launch plus target detection and local cache
metadata work. It does not proxy Rust/Dart worker IPC, scan build inputs, or
schedule actions. A frontend cache hit therefore adds only startup overhead; a
worker AOT cache miss additionally compiles the workspace-local worker before
the first dirty build. Direct binary selection through
`BUILD_RUNNER_ACCELERATOR_BIN` remains available for benchmarking, offline
environments, and CI images that preinstall the frontend.
