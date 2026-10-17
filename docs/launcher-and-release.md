# Launcher and release contract

The Dart package contains the launcher, manifest generator, and worker. The
launcher selects a matching Rust frontend when available and otherwise follows
the mode-specific fallback rules below.

## Install and invoke

```bash
dart pub add dev:build_runner_accelerator
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
```

`dart run` starts the launcher. Worker AOT settings control the generated Dart
worker, not the launcher.

## Modes and CLI

| Mode | Native unavailable or unsupported request |
| --- | --- |
| `auto` (default) | Explain on stderr, then run stock `build_runner`. |
| `rust` | Return an error before native actions. |
| `dart` | Always run stock `build_runner`. |

The launcher recognizes these options:

| Option | Purpose |
| --- | --- |
| `--mode auto`, `--mode rust`, `--mode dart` | Select native/fallback policy. |
| `--root PATH`, `--dart PATH` | Select workspace or Dart executable. |
| `--jobs N`, `--interval-ms N` | Configure the native frontend. |
| `--force-aot`, `--force-jit` | Select worker execution mode; mutually exclusive. |
| `--only-check`, `--keep-modified-outputs` | Build-only output policies for the normal-builder demand subset; see [output policies](#output-policies). |
| `--build-filter PATTERN` | Select build/watch outputs; syntax and manifest limits are in [ADR 0032](adr/0032-native-build-filter-demand-and-output-state.md). |
| `--define`, `--release`, `--no-release`, `--config` | Resolve `build_runner` settings; see [configuration](configuration.md). |
| `--delete-conflicting-outputs`, `-d` | Accepted retired flags in `build_runner` 2.16.2; they have no effect and are never added automatically. |
| `prewarm [--background]` | Prepare caches without running builders. |
| `aot-cache-key` | Print a native worker cache key; no stock equivalent. |

Unsupported commands and options fall back before native download or
workspace setup in `auto`; `rust` rejects them. Fallback retains the original
argument order, values, `--` separator, and explicit `--force-aot`/`--force-jit`
flags, and preserves
stock's exit status. Stock option values remain values even when they resemble
accelerator options. Invalid accelerator values are errors in every mode.
Leading help/version describe the accelerator; command help/version route to
stock in `auto` and are rejected in `rust`. The internal `--worker` and transport
options are for tests and diagnostics, not third-party extension APIs.

In `auto`, these option groups also route to stock:

| Stock-only group | Examples |
| --- | --- |
| Output layout or build directory | `--output` / `-o`, `--workspace`, positional build directories |
| Output layout and logging | `--symlink`, `--no-symlink`, `--verbose` / `-v`, `--verbose-durations` |
| Dart runtime or profiling | `--enable-experiment`, `--dart-jit-vm-arg`, `--dart-aot-perf` |
| Serve and daemon | `--hostname`, `--log-requests`, `--live-reload`, `--build-mode` |
| Other stock commands or arguments | `clean`, `serve`, `run`, `test`, `stop`, `daemon`, unknown arguments, invalid stock values |

Strict `rust` mode rejects these requests. Prewarm has no stock equivalent:
it accepts supported configuration settings but rejects stock-only and
build-only arguments.

## Output policies

`build --only-check` verifies expected package-path outputs without writing or
removing generated files. It reports incorrect (`I`), missing (`M`), and
unexpected (`U`) files and exits 1 on differences. Cache intermediates are not
compared or saved, and incremental graph changes are not saved, even on success.
Setup/compilation caches may still change. A later ordinary build applies the
uncommitted results normally.

`build --keep-modified-outputs` retains existing manually edited outputs while
their producer can be reused. Missing outputs are regenerated. An input change
can rerun the builder and overwrite manual changes; deleted inputs or omitted
outputs remove old generated files. Retention is not permanent protection.

These flags cannot be combined or negated; repeating the same flag is allowed.
They support multiple outputs, dependency chains, source/cache intermediates,
and supported build filters. Optional/post-process/trigger-only/zero-output
builders and unsupported prior-state transitions route to stock in auto and
error in rust. Starting native watch from a graph with retained output history
also requires stock fallback, including after ordinary builds. Watch with either flag routes before native setup; prewarm
rejects both. Dart delegates all policy behavior to stock. See
[ADR 0034](adr/0034-native-output-policies.md) for state and commit guarantees.

When keep finds modified generated outputs, builders using digest/resolver APIs
use stock in auto and error before publication in rust; stock exposes old digest
values alongside retained bytes. Builders cannot suppress this boundary by
catching the API exception. After stock keep or fallback from retained history, later build/watch
commands stay on stock until both disposable states are reset using the
[recovery guide](compatibility-cleanup.md#safe-recovery). This avoids reusing an
older native graph against stock's newer keep history; the launcher routes this
state before native acquisition. A publishing dart-mode build/watch after native
keep also claims stock ownership; verification/help does not.

## Environment controls

Names below use the `BUILD_RUNNER_ACCELERATOR_` prefix. Unknown names are
ignored. Public compatibility intent applies only to the Public row.

| Class | Suffixes | Use |
| --- | --- | --- |
| Public | `BIN`, `CACHE`, `RELEASE_BASE_URL`, `WORKER_AOT` | Select a preinstalled binary, cache root, HTTPS release mirror, or worker compilation policy. |
| Diagnostics | `DEBUG`, `METRICS`, `ANALYSIS_TRACE`, `WALL_TRACE`, `PLAN_ONLY` | Error details, worker metrics, analysis/timing traces, and plan inspection. Traces need `METRICS`; `PLAN_ONLY` exits before actions. Output schemas are not stable. |
| Cache recovery | `BYTE_STORE`, `DEP_CACHE`, `DEP_PREFETCH`, `MANIFEST_SNAPSHOT`, `EARLY_CATALOG`, `PART_FILTER`, `SDK_SUMMARY_PREWARM`, `ANALYSIS_PREWARM` | Set the named optimization to `0` for diagnosis. `BYTE_STORE` and `DEP_CACHE` disable their shared caches; `BYTE_STORE` also accepts `false`/`off`. |
| Experimental | `ANALYSIS_SINGLE_FLIGHT`, `COMPILE_PREWARM`, `MANIFEST_PREWARM` | Opt-in experiments; disabled by default and subject to change. |
| Tuning | `ANALYSIS_PREWARM_JOBS`, `ANALYSIS_PREWARM_DIRS`, `RESOLVER_CAP` | Prewarm and resolver limits; no performance guarantee. |
| Internal | `WORKER_KERNEL`, `WORKER_AOT_PATH`, `WORKER_AOT_BACKGROUND_LOCK`, `MANIFEST_WORKER_AOT`, `SUPERVISED` | Artifact overrides and process coordination. Do not set in ordinary builds. |

Toolchain variables such as `DART_BIN`, `CARGO_BIN`, `PUB_CACHE`, `RUSTUP_HOME`, and
`CARGO_HOME` belong to repository scripts, not the launcher API. Retired names
and recovery steps are in the [compatibility cleanup guide](compatibility-cleanup.md).

## Prewarm

Run prewarm after dependency resolution to prepare the manifest, worker, and
analysis cache before the first build:

```bash
dart pub get
dart run build_runner_accelerator prewarm --background
```

Background prewarm returns promptly and logs to
`.dart_tool/build_runner_accelerator/prewarm.log`. A worker AOT compile lock
prevents duplicate worker AOT compiles. Prewarm runs no build actions. Under
`auto`, it reports and exits successfully when native execution is unavailable;
`dart` mode skips it and `rust` stays strict. Filters and other build-only
arguments are rejected. Set `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM=0` to
skip its analysis sweep.

## Binary selection and integrity

Frontend resolution checks, in order:

1. `BUILD_RUNNER_ACCELERATOR_BIN`.
2. A workspace binary under `.dart_tool/build_runner_accelerator/bin/`.
3. The versioned user cache.
4. The matching GitHub Release artifact.
5. Stock fallback in auto.

A release manifest and detached Ed25519 signature are verified before
downloaded code is used. The launcher checks target, package version, protocol
major, archive size, and SHA-256; cache entries are re-hashed before execution.
Temporary files, atomic renames, and per-target locks protect installation.
`BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL` may select an HTTPS-compatible
mirror.

| Target | Rust target | Archive |
| --- | --- | --- |
| macos-arm64 | aarch64-apple-darwin | tar.gz |
| linux-x64 | x86_64-unknown-linux-gnu | tar.gz |
| linux-arm64 | aarch64-unknown-linux-gnu | tar.gz |
| windows-x64 | x86_64-pc-windows-msvc | zip |
| windows-arm64 | aarch64-pc-windows-msvc | zip |

macOS Intel uses stock in `auto`. The signed release workflow requires
`BUILD_RUNNER_ACCELERATOR_ED25519_PRIVATE_KEY` in repository Actions secrets;
the corresponding public key is pinned in the package.

The release cache is separate from workspace state. It uses the platform
cache directory or `BUILD_RUNNER_ACCELERATOR_CACHE` override:

| Platform | Default cache root |
| --- | --- |
| Linux | `XDG_CACHE_HOME/build_runner_accelerator` or `~/.cache/build_runner_accelerator` |
| macOS | `~/Library/Caches/build_runner_accelerator` |
| Windows | `%LOCALAPPDATA%/build_runner_accelerator` |

Manifests, graphs, generated workers, and workspace AOT artifacts live under
`.dart_tool/build_runner_accelerator/`. `dart compile exe` for the launcher is
a compatibility path for cache misses; `dart run` is the normal invocation.

## Worker lifecycle and signals

Native build/watch supervises its worker, generator, and compiler processes.
On Unix, the launcher forwards Ctrl-C to the selected child and forwards SIGHUP
to native or stock execution; they return 130 and 129 after bounded cleanup.
Windows native execution uses a kill-on-close job and forwards console
interruption. Detached prewarm intentionally survives successful setup;
interrupted or failed work is cleaned up. Direct stock and native execution
preserve the selected process's standard streams; launcher diagnostics go to
stderr.

Worker AOT policy is command-specific: one-shot builds compile synchronously;
watch starts the script worker and compiles AOT in the background. The session
keeps the worker it started with. `BUILD_RUNNER_ACCELERATOR_WORKER_AOT` accepts:

| Value | Behavior |
| --- | --- |
| `1` | Compile synchronously. |
| `background` | Compile in a background process. |
| `force` | Require AOT; compile failure is fatal. |
| `0` or another value | Use the kernel/script worker. |

Explicit `--force-aot`/`--force-jit` take precedence. See the
[development guide](development.md) for toolchain and release checks, and
[protocol v1](../protocol/v1.md) for the internal worker contract.
