# Launcher and release contract

`build_runner_accelerator` is the single project-facing Dart package. It
contains the launcher, manifest generator, worker runtime, and protocol
libraries so the generated worker and native frontend share one versioned
contract.

## Invocation

Add the package to a target project's `dev_dependencies`:

```yaml
dev_dependencies:
  build_runner_accelerator: ^0.1.0-dev.1
```

Invoke the project-local executable:

```bash
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
```

These are the normal invocations: `dart run` starts the project-facing
launcher as a Dart program. Launcher execution and worker execution are
separate layers. The AOT options below select the generated Dart worker; they
do not compile the launcher itself.

The launcher consumes `--mode`, `--root`, `--dart`, `--force-aot`, and
`--force-jit`. Native frontend options such as `--jobs`, `--interval-ms`, and
`--worker` are passed to the native frontend. The compile-mode options use the
stock build_runner names, are mutually exclusive, and are retained when the
stock Dart path is selected. Other arguments are retained for the stock Dart
path.
Unsupported commands and options select stock immediately in `auto`, before
binary resolution, download, workspace loading, or manifest generation.
`rust` rejects them explicitly. Stock option values and `--` are retained,
including values that look like accelerator flags; argument order is preserved.
Both direct Dart fallback and manifest-time native fallback retain the same
stock invocation, including explicit force flags, and propagate stock's status.
The native bridge carries a JSON argument vector internally; it is not a
user-facing option.

Native build/watch also accept `--delete-conflicting-outputs` and `-d`.
In the supported build_runner 2.16.2 window these are retired, non-negatable,
non-operational flags. No path automatically adds them. `--build-filter`,
output directories, build directories, config/define/release/workspace,
keep-modified-outputs, only-check, logging, serve options and other stock
options remain on fallback. See the complete [CLI table](../README.md).

Leading help/version belong to the accelerator; command-level help/version
belong to stock. `prewarm` rejects stock-only arguments in every mode.
`aot-cache-key` is a native utility with no stock equivalent.
Stock clean does not remove accelerator graph/worker caches.

Direct stock execution on Unix uses a small source/AOT launcher re-entry that
creates a session and execs the selected Dart command. This preserves its PID,
argument vector, stdio and status while allowing launcher-only Ctrl-C to reach
the inner stock build process. Shutdown is bounded to five seconds.

On Unix the native process supervises a separate process group containing its
workers, generator, probes and compilers. Launcher signals are forwarded to the
selected child; native forwards them to the whole group, waits up to five
seconds, and kills remaining members. Ctrl-C returns 130; terminal/SSH hangup
(SIGHUP) is forwarded in both native and stock paths and returns 129. Internal AOT helpers
share the supervisor context; an intentional background compile can finish
after a successful build, but is cleaned up on interruption or failure. Detached prewarm has its own session and intentionally survives
the setup hook. Windows native execution uses a kill-on-close job and forwards
console interruption to the child group; the Windows execution path requires CI
validation on that platform. Detached Windows prewarm retries without job
breakaway only for ERROR_ACCESS_DENIED. It then remains subject to any enclosing
job's lifetime, while the accelerator job permits it to survive successful setup.

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
The default policy depends on the command: `build` and other one-shot
commands compile the AOT worker synchronously, because running a large cold
build on the script worker costs more than the one-time compile, while
`watch` starts the Dart script worker immediately and compiles the AOT
binary in the background so the session is not held up. A long-running
`watch` session keeps the artifact it
started with so the resident worker is not replaced mid-session; a later
invocation can use the completed AOT cache. Set the variable to `1` for a
synchronous compile on the first build, to `background` for the background
compile, or to `0` to keep the kernel/script
worker path. Explicit
`--force-aot` and `--force-jit` take precedence over the environment variable;
`--force-aot` also makes an AOT compilation failure fatal, matching stock
build_runner's force semantics.

## Setup-time prewarm

The `prewarm` command exists so the one-time worker AOT compile can happen at
setup time — right after `dart pub get` — instead of inside the first `build`:

```bash
dart pub get
dart run build_runner_accelerator prewarm --background
```

It drives the same manifest-generation, worker-selection, and compile stages
as a cold `build`, without running build actions, and leaves every populated
cache where the next `build` finds it. With `--background` the command returns
immediately: a detached copy (new process group, lowered scheduling priority)
does the work and logs to
`.dart_tool/build_runner_accelerator/prewarm.log`. `--background` is accepted
only with `prewarm`.

A workspace-local single-flight lock
(`.dart_tool/build_runner_accelerator/.aot-background.lock`) serializes all
worker AOT compiles: a `prewarm` in flight and a `build` (or a second
`prewarm`, which exits as a no-op) never run two compiles — the loser waits
for the winner's atomically published artifact up to a bounded interval and
then compiles itself. `prewarm` is a setup hook, not a contract: under
`--mode dart` or when no native frontend can run it reports on stderr and
exits 0, so a dependency-resolution hook cannot fail for lack of a frontend.
`--mode rust` keeps strict semantics.

Beyond the AOT compile, `prewarm` also resolves the workspace's sources into
the shared analyzer byte store (the `analysis prewarm[prewarm]` shards),
which is what makes the first build's action phase faster — not just the
compile-free startup. On a large workspace that sweep roughly doubles the
command's serial time, so `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM=0` opts
out for foreground or CI runs where it has nothing to hide behind; it stays
on by default because a detached `prewarm --background` hides the cost
entirely.

The old `aot-prewarm` alias is removed at both CLI boundaries; use `prewarm`.

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

The launcher keeps the archive, crypto, and signature-verification dependency
graph out of the normal Dart startup path. On a valid release-cache hit it
checks the small metadata file and re-hashes the executable using the
platform's SHA-256 command, then launches the native frontend immediately.
Only a cache miss starts `release_downloader_entrypoint.dart` in a short-lived
isolate; that isolate performs the signed manifest, archive, and atomic install
work. If the platform hash utility is unavailable, the conservative downloader
path performs the full validation instead.

### Optional precompiled launcher

The release package distributes a Dart launcher, not a native AOT launcher.
An advanced user can nevertheless run `dart compile exe` against the launcher
entrypoint. In that form Dart cannot spawn the source downloader directly as an
isolate, so a release-cache miss invokes the same downloader entrypoint through
the configured `--dart` executable as a short-lived child process. This is a
compatibility path; normal installation and the launcher-inclusive benchmark
use `dart run`.

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

### Release signing setup

The release workflow expects the repository Actions secret
`BUILD_RUNNER_ACCELERATOR_ED25519_PRIVATE_KEY` to contain the PEM-encoded
Ed25519 private key corresponding to the public key pinned in
`lib/src/release_downloader.dart`. The workflow verifies that correspondence
before signing and never checks the private key into the repository.

## Launcher overhead

The launcher adds one Dart process launch plus target detection and local cache
metadata work. It does not proxy Rust/Dart worker IPC, scan build inputs, or
schedule actions. A workspace or valid release-cache hit therefore adds only
lightweight startup overhead; a release cache miss starts the downloader
isolate, and a worker AOT cache miss additionally compiles the workspace-local
worker before the first dirty build. Direct binary selection through
`BUILD_RUNNER_ACCELERATOR_BIN` remains available for benchmarking, offline
environments, and CI images that preinstall the frontend.

## Compatibility cleanup during 0.x

This cleanup prepares for an eventual 1.0 while development continues through
0.x releases. It does not select the next release version or finalize the
1.0 API. See [the cleanup/update guide](compatibility-cleanup.md) for the current
CLI/environment classification and internal state recovery. `aot-prewarm` is
removed. Custom workers must match the package/native version exactly and pass version/capability validation.
Storage formats are regenerated on invalidation and are not stable API.
