# Launcher and release contract

The Dart package contains the launcher, manifest generator, and worker. The
launcher requires a matching Rust frontend. Unsupported or unavailable native
execution fails explicitly; stock build_runner is never launched.

## 1.x compatibility contract

This is the compatibility baseline for 1.0 and subsequent 1.x releases.
The package is currently 0.x; this document does not announce a 1.0 release.

- The supported SDK and core dependency constraints are listed in
  [supported dependencies](#supported-dependencies) and declared in `pubspec.yaml`.
  Their intersection must resolve in Pub. CI checks two points, Dart 3.11.0
  with minimum dependencies and Dart 3.13.3 with current dependencies; it does
  not test every SDK or every combination allowed by the constraints.
- Within the supported manifest/configuration subset, successful generated
  file sets and contents follow stock build_runner. Builder support is scoped
  to the configurations in the [probe inventory](compatibility-probes.md),
  fixture lockfiles, and [configuration guide](configuration.md), rather than
  every feature of a named builder. New dependency releases within constraints
  still need validation, especially private build_runner and analyzer APIs.
- The commands/options below, their documented combination restrictions, and
  the Public environment row are the supported user interface. Existing
  supported invocations and output/failure guarantees are maintained in 1.x;
  removing them or narrowing the declared support window requires a major
  release. Additive options and support may be introduced in minor releases.
- Success exits 0. Invalid/unsupported requests, setup errors and failed builds
  exit nonzero (normally 1); `--only-check` exits 1 for output differences.
  Unix interruption statuses are documented under [signals](#worker-lifecycle-and-signals).
  Watch can report a builder failure and remain alive for the next edit.
  Exact diagnostic text, progress logs, timing and diagnostic schemas are not API.
- Builder failures publish no staged outputs or graph. Interrupted publication
  uses undo recovery before reuse, with the filesystem and external-edit limits
  in [the recovery guide](compatibility-cleanup.md#interrupted-publication).
  These guarantees do not imply a simultaneously atomic file tree or power-loss
  durability. Filter selection and output retention have the restrictions below;
  watch accepts value-only configuration reloads and rejects topology changes
  as described in [configuration](configuration.md#watch-and-cache-behavior).
- Stop native processes before running stock directly. Follow the
  [upgrade and recovery steps](compatibility-cleanup.md#safe-recovery) before
  returning to native or resetting state; preserve pending undo evidence.
  There is no automatic stock fallback.
- Internal IPC, graph/manifest/journal formats and paths, generated workers,
  compiled AOT/kernel artifacts, analysis caches and `lib/src` are not public
  extension or persistence APIs. They can change in 1.x and caches may regenerate.
  Package and frontend versions must match; cross-version worker reuse is not
  promised. Internal state changes must preserve user sources and the documented
  failure/recovery boundary, including refusal when undo recovery is unsafe.
  No stable Dart library API, performance threshold, or extra platform minimum
  beyond the documented distribution evidence is promised.

The [SDK lifecycle comparison](development.md#sdk-lifecycle-comparison) checks
real Resolver-based generation and incremental/watch behavior in addition to
package analysis/tests. Distribution and interrupted-publication tests remain
separate gates, so SDK coverage does not imply all platform/SDK combinations.

## Supported dependencies

The release line supports Dart >=3.11.0 <4.0.0. CI checks a minimum solution
with Dart 3.11.0 and a current solution with Dart 3.13.3. The core package
window is:

| Package | Supported version |
| --- | --- |
| analyzer | >=13.3.0 <15.0.0 |
| build | >=4.0.9 <5.1.0 |
| build_config | >=1.3.2 <1.5.0 |
| build_runner | >=2.15.3 <2.18.0 |
| package_config | >=2.2.0 <4.0.0 |

The runner upper bound protects private worker interfaces. Runners 2.15.3, 2.16.0 and 2.16.1
allow Analyzer 13.3; the accelerator backports #5197 in an isolated compilation
resolution so those runners also work with Analyzer 14.5 and newer. Runner
2.16.2 retains its upstream Analyzer 14.3 floor. See
[ADR 0042](adr/0042-runner-resolver-compatibility.md) for the adapter boundary.
One package and the existing release pipeline cover these resolutions. Runner 2.15.3's default output retention
is selected internally, with the existing retained-output API safety limits.

For the 2.17 line, the validated and supported version is 2.17.1, which uses
build 5.0 and build_config 1.4. Builders must themselves allow build 5.0;
expanding the accelerator's range does not override generator constraints.
Runner 2.17.0 depends on the retracted build 4.1.0 and is outside the validated
support scope, although the continuous Pub constraint includes it. Use 2.17.1
when selecting a 2.17 release.

Shared-library parts (`adds_to_library: true`) use native phase
aggregation and transactional part-directive updates. `--enable-experiment`
enables language experiments for generated workers, including `enhanced-parts`
for `LibrarySourceSink.addImport`. Shared builders currently require an
unfiltered build without explicit `--keep-modified-outputs`. Input additions,
renames and deletions also support downstream normal resolvers. Stock 2.17.1
has an incremental partial-content cache defect; the comparison corrects an isolated stock copy and additionally checks unmodified
clean stock outputs. See [ADR 0043](adr/0043-shared-library-parts.md).

`dart run` starts the launcher; see the [installation guide](../README.md#installation).
Worker AOT settings control the generated Dart worker, not the launcher.

## Native-only CLI

0.14.0 removes automatic stock fallback and all `--mode` values. Old mode
arguments fail with migration guidance. Use `dart run build_runner` directly
when stock is needed. Command-level and leading help/version describe the
accelerator and do not require a native binary.

`help`, `--help` and `-h` show the command overview. Use `help build` or
`build --help` (also `-h`) for command-specific options; the same forms work
for `watch` and `prewarm`. Help is handled by the Dart launcher
without downloading a frontend, starting a worker or creating build state.
Omitting the command still runs `build`.

The launcher recognizes these options:

| Option | Purpose |
| --- | --- |
| `--root PATH`, `--dart PATH` | Select workspace or Dart executable. |
| `--jobs N`, `--interval-ms N` | Configure the native frontend. |
| `--force-aot`, `--force-jit` | Select worker execution mode; mutually exclusive. |
| `--only-check`, `--keep-modified-outputs` | Build-only output policies for the normal-builder demand subset; see [output policies](#output-policies). |
| `--build-filter PATTERN` | Select build/watch outputs; syntax and manifest limits are in [ADR 0032](adr/0032-native-build-filter-demand-and-output-state.md). |
| `--workspace` | Build all packages in a Pub workspace within the subset below. |
| `--define`, `--release`, `--no-release`, `--config` | Resolve `build_runner` settings; see [configuration](configuration.md). |
| `--enable-experiment NAME` | Enable Dart language experiments in generated workers; repeat or comma-separate. Shared-part imports require `enhanced-parts`. |
| `--delete-conflicting-outputs`, `-d` | Accepted retired flags throughout the supported runner window; they have no effect and are never added automatically. |
| `prewarm [--background]` | Prepare caches without running builders. |

Unsupported commands and options fail before native download or workspace
setup. Configuration values retain their token boundaries, even when they
resemble launcher flags. `--` ends accelerator option parsing; positional build
directories remain unsupported. The internal `--worker` option is for tests and
diagnostics, not a third-party extension API.

The following stock features require a direct stock invocation:

| Stock-only group | Examples |
| --- | --- |
| Output layout or build directory | `--output` / `-o`, positional build directories |
| Output layout and logging | `--symlink`, `--no-symlink`, `--verbose` / `-v`, `--verbose-durations` |
| Dart runtime or profiling | `--dart-jit-vm-arg`, `--dart-aot-perf` |
| Serve and daemon | `--hostname`, `--log-requests`, `--live-reload`, `--build-mode` |
| Other stock commands or arguments | `clean`, `serve`, `run`, `test`, `stop`, `daemon`, unknown arguments, invalid stock values |

These requests are rejected. Prewarm has no stock equivalent:
it accepts supported configuration settings but rejects stock-only and
build-only arguments. Package-path output conflicts in dependencies also require
a direct stock invocation, including ordinary builds and watches; native fails before actions.

### Workspace builds

`build --workspace` resolves the Pub workspace from the current package and
writes source outputs in all output packages. Outside a Pub workspace it builds
the current package. Workspace builds currently accept non-optional normal and post-process
builders without shared parts or trigger-only execution, and reject overlapping
nested source sets. Output package paths must resolve inside the workspace root
and must be distinct. Validated fixtures cover a normal builder and JSON Serializable with source_gen
combining and part cleanup in two members; other configurations require their
own stock comparison. `watch`, build
filters, output policies, named configs and `--define` are unsupported with
`--workspace`. These are accelerator limitations, not stock build_runner
limitations; remaining work is tracked in the [roadmap](roadmap.md#compatibility).
Unavailable combinations fail before actions.

Native locks every output package and keeps one graph at the workspace root.
Independent packages can execute concurrently within a generated phase;
`--jobs` bounds the total resident workers across the workspace. Package/target
dependencies and phase barriers are preserved, and outputs plus graph are
published only after all actions succeed. See [ADR 0046](adr/0046-workspace-action-scheduler.md).
Switching between workspace and individual-package builds, or changing the set
of output packages, requires the [state reset](compatibility-cleanup.md#safe-recovery).
Individual-package prewarm also requires that reset after
a workspace build.
If a background worker compilation lock exists in an output package, the
workspace build fails; wait for compilation to finish before retrying.
Pending publication recovery must be resolved before any reset. See
[ADR 0045](adr/0045-pub-workspace-builds.md).

## Build filters

Repeat `--build-filter` or supply comma-separated patterns to select outputs and
their required producers. A selected action may write its other declared
outputs; a filter with no matches succeeds. Filters limit demand but do not
preserve every unselected generated file across later builds/watch restarts.
Unsupported syntax, builder shapes and prior-state transitions fail explicitly.

An unchanged filtered build starts no worker. Dirty filtered builds use one
worker by default; `--jobs N` allows up to N workers, capped by dirty roots.
Disabling the shared byte store forces one worker. See
[ADR 0032](adr/0032-native-build-filter-demand-and-output-state.md) for graph,
deletion and source-observation rules and
[ADR 0033](adr/0033-filtered-demand-scheduler.md) for scheduling.

## Output policies

Ordinary build/watch follows the resolved runner's default: 2.15.3 retains
modified outputs, while 2.16+ repairs them. This is selected internally without
adding CLI flags or the explicit demand-mode restrictions below. The retained
output API safety boundary still applies when unrelated edits must survive a
build, as described below.
Upgrading the runner restores its new default without clearing native state.

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
builders and unsupported prior-state transitions fail explicitly. Starting native
watch from a graph with retained output history is also unsupported, including
after ordinary builds. Watch and prewarm reject both flags before native setup. See
[ADR 0034](adr/0034-native-output-policies.md) for state and commit guarantees.

When keep finds modified generated outputs, builders using digest/resolver APIs
fail before publication; stock exposes old digest values alongside retained
bytes that native cannot reproduce. Builders cannot suppress this boundary by
catching the API exception. The entire staged transaction is discarded.

A legacy `stock-output-policy-state` marker from earlier releases blocks native
build/watch before binary acquisition or manifest preparation. The accelerator
never clears it automatically or imports stock logical digest history. Follow
the [recovery guide](compatibility-cleanup.md#safe-recovery) to reset both states.
Direct stock commands do not create or update accelerator ownership markers;
stop all builders and follow the recovery guide before returning to native.

## Environment controls

Names below use the `BUILD_RUNNER_ACCELERATOR_` prefix. Unknown names are
ignored. Public compatibility intent applies only to the Public row.

| Class | Suffixes | Use |
| --- | --- | --- |
| Public | `BIN`, `CACHE`, `RELEASE_BASE_URL`, `WORKER_AOT` | Select a preinstalled binary, cache root, HTTPS release mirror, or worker compilation policy. |
| Diagnostics | `DEBUG`, `METRICS`, `ANALYSIS_TRACE`, `WALL_TRACE`, `PLAN_ONLY` | Error details, worker metrics, analysis/timing traces, and plan inspection. `ANALYSIS_TRACE` needs `METRICS`; `WALL_TRACE` is independent. `PLAN_ONLY` exits before actions. Output schemas are not stable. |
| Experimental | `EXPERIMENTAL_COMPILE_ISOLATION` | `1` enables compiler-only dependency copies for the bounded dependency window in [ADR 0047](adr/0047-experimental-compile-isolation.md). Disabled by default; not a public compatibility guarantee. |
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
prevents duplicate worker AOT compiles. Prewarm runs no build actions. It fails
explicitly when native execution is unavailable or unsupported. Filters and other
build-only arguments are rejected. Set `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM=0` to
skip its analysis sweep.

### CI caches

Restore the cache directory selected by `BUILD_RUNNER_ACCELERATOR_CACHE`
before running foreground `prewarm` or `build`, then save it using your CI
provider. Include OS/architecture, package version, SDK, resolved dependencies
and relevant source changes in the provider's cache key. The cache holds both
worker AOT artifacts and analyzer entries; no accelerator key command is needed.
Build and prewarm validate restored artifacts and regenerate stale entries.
Internal keys, metadata and cache layouts are not public persistence APIs.

## Binary selection and integrity

Frontend resolution checks, in order:

1. `BUILD_RUNNER_ACCELERATOR_BIN`.
2. A workspace binary under `.dart_tool/build_runner_accelerator/bin/`.
3. The versioned user cache.
4. The matching GitHub Release artifact.

A miss or verification/download failure is an error.

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

macOS Intel has no published native artifact; use a compatible preinstalled
binary or run stock directly. Maintainers should use
[distribution validation](distribution-validation.md) for signing setup,
publication gates and workflow replay.

Linux builds currently use Ubuntu 24.04 (glibc 2.39). They are GNU/glibc binaries;
older glibc distributions and musl/Alpine are unverified. macOS/Windows minimum
OS versions are also unverified beyond the named CI images. Producer artifacts
record imported GLIBC symbols or macOS deployment metadata; see the
[platform facts](distribution-validation.md#platform-facts-and-unverified-minimums).

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

## Verify downloaded release provenance

The launcher retains its pinned Ed25519 manifest signature and archive/cache
integrity checks. GitHub Artifact Attestation separately lets users verify which
repository, source commit and release workflow produced a downloaded archive
or manifest. Attestation verification is performed by release CI and explicitly
by users; the launcher does not invoke GitHub CLI or verify attestations.

See [download and verification commands](distribution-validation.md#artifact-attestation)
for GitHub CLI >=2.80.0, authentication, exact commit/workflow/tag checks and
failure handling. Current archives have no configured macOS Developer ID
signing/notarization or Windows Authenticode. These are post-1.0 work;
attestation does not establish Gatekeeper/SmartScreen approval. See the
[platform conditions](distribution-validation.md#platform-facts-and-unverified-minimums).

## Worker lifecycle and signals

Native build/watch supervises its worker, generator, and compiler processes.
On Unix, the launcher forwards Ctrl-C to the selected child and forwards SIGHUP
to native execution; they return 130 and 129 after bounded cleanup.
Windows native execution uses a kill-on-close job and forwards console
interruption. Detached prewarm intentionally survives successful setup;
interrupted or failed work is cleaned up. Native execution preserves the
process's standard streams; launcher diagnostics go to stderr.

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
