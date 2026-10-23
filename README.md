# build_runner_accelerator

An experimental Rust frontend for [build_runner](https://pub.dev/packages/build_runner). Rust plans actions and manages incremental state; a Dart worker runs builders through build_runner APIs.

Before adopting the tool, read the [1.x compatibility contract](docs/launcher-and-release.md#1x-compatibility-contract)
for supported SDKs, tested workloads, public interfaces, and limits.

## Installation

The current package version is `0.15.0`.

Add the package to your application:

```bash
dart pub add dev:build_runner_accelerator:^0.15.0
```

Or add it to `pubspec.yaml`:

```yaml
dev_dependencies:
  build_runner_accelerator: ^0.15.0
```

Then use the project-local command:

```bash
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
```

To warm the worker before the first build, run this after pub get:

```bash
dart run build_runner_accelerator prewarm --background
```

Prewarm prepares caches but does not run build actions. It is optional.

## Native execution

The launcher downloads and verifies a matching native binary. Builds, watches,
and prewarm fail explicitly when the binary or requested feature is unavailable.
Stock build_runner is never started by the accelerator. To use stock, run
`dart run build_runner build` or `dart run build_runner watch` directly.

**Breaking in 0.14.0:** automatic stock fallback and `--mode` are removed.
Remove `--mode auto` and `--mode rust` from accelerator commands. Replace
`--mode dart` commands with direct stock invocations. macOS Intel needs a
compatible preinstalled native binary or direct stock execution. See the
[upgrade and recovery guide](docs/compatibility-cleanup.md).

## Build selected outputs

Use `--build-filter` to build matching outputs and the producers they need:

```bash
dart run build_runner_accelerator build --build-filter='lib/*.g.dart'
```

Repeat the option or provide comma-separated patterns to select more outputs.
A selected action may write its other declared outputs too. A filter with no
matches succeeds.

| Filtered build state | Worker policy |
| --- | --- |
| No demanded changes | No artifact resolution, worker start, or initialization |
| Dirty roots, default | One worker |
| Explicit `--jobs N` | Up to N workers, capped by dirty-root count, when the shared byte store is enabled |
| `BUILD_RUNNER_ACCELERATOR_BYTE_STORE=0` | One worker, even when `--jobs` is set |
| Unfiltered build | Existing machine-based default |

See [ADR 0033](docs/adr/0033-filtered-demand-scheduler.md) for worker ownership,
failure, and scaling limits.

Filters limit demand; they do not guarantee that unselected generated files
remain on disk across later builds or watch restarts. Unsupported filter syntax,
builder types, or prior-state transitions fail with an explicit error. See [ADR 0032](docs/adr/0032-native-build-filter-demand-and-output-state.md)
for the selection, dependency, deletion, and failure rules.

## Verify or retain generated outputs

```bash
dart run build_runner_accelerator build --only-check
dart run build_runner_accelerator build --keep-modified-outputs
```

Verification exits 1 on output differences without writing generated files or
incremental state. Keep retains manual edits until the producer reruns; missing
outputs regenerate. Both flags support normal-builder chains and build filters,
and are mutually exclusive and build-only in native mode. See the
[output policy reference](docs/launcher-and-release.md#output-policies) for
compatibility limits and state recovery.

## Compatibility and recovery

The native frontend supports build_runner `>=2.16.2 <2.17.0`; correctness
comparisons use stock build_runner 2.16.2. Its supported manifest subset is
checked for byte-identical outputs and incremental, failure, deletion, rename,
and watch behavior. Requests outside that subset fail explicitly.

Native build and watch commands acquire an exclusive workspace lock; a competing
native invocation fails. Direct stock runs bypass that lock. Do not run stock
concurrently with a native command in the same workspace.

A builder failure leaves native outputs and graph at their last successful
state. An undo journal detects interrupted publication and restores the previous
outputs and graph before the next native build/watch reuses them. Unexpected
external edits or damaged recovery evidence stop recovery with instructions.
Publication is not a simultaneous atomic snapshot and has no power-loss
durability guarantee. See the [recovery guide](docs/compatibility-cleanup.md#interrupted-publication).

Successful native builds retain build-start evidence for existing sources,
keeping edits or deletions during actions visible to the next build or watch
cycle. Filtered builds also retain first worker observations of eligible
external sources absent at build start; see
[ADR 0032](docs/adr/0032-native-build-filter-demand-and-output-state.md).

## Project guides

| If you need to… | See |
| --- | --- |
| Check supported CLI options, modes, and environment controls | [Launcher reference](docs/launcher-and-release.md) |
| Understand `build.yaml`, `--define`, release, and named-config behavior | [Configuration guide](docs/configuration.md) |
| Review native build-filter guarantees and limits | [ADR 0032](docs/adr/0032-native-build-filter-demand-and-output-state.md) |
| Understand Rust/Dart responsibilities and IPC | [Protocol v1](protocol/v1.md) and [ADR index](docs/adr/README.md) |
| Contribute or run correctness checks | [Development guide](docs/development.md) |
| Review measured performance | [Benchmarks](docs/benchmarks.md) |
| Check release status and remaining work | [Roadmap](docs/roadmap.md) |

For updates that affect existing workspaces, use the
[compatibility cleanup guide](docs/compatibility-cleanup.md).
