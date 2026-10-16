# build_runner_accelerator

An experimental Rust frontend for [build_runner](https://pub.dev/packages/build_runner). Rust plans actions and manages incremental state; a Dart worker runs builders through build_runner APIs.

## Installation

The current package version is `0.11.0`.

Add the package to your application:

```bash
dart pub add dev:build_runner_accelerator:^0.11.0
```

Or add it to `pubspec.yaml`:

```yaml
dev_dependencies:
  build_runner_accelerator: ^0.11.0
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

## Choose a frontend

| Mode | Behavior |
| --- | --- |
| auto (default) | Use native execution when supported; otherwise run stock build_runner. |
| rust | Require native execution; report an error if the request is unsupported. |
| dart | Always use stock build_runner. |

The launcher downloads and verifies a matching native binary where one is
available. Auto falls back to stock build_runner on unsupported platforms,
including macOS Intel. See [launcher and release details](docs/launcher-and-release.md).

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
builder types, or prior-state transitions use stock in auto and report an error
in rust. See [ADR 0032](docs/adr/0032-native-build-filter-demand-and-output-state.md)
for the selection, dependency, deletion, and failure rules.

## Compatibility and recovery

The native frontend supports build_runner `>=2.16.2 <2.17.0`; correctness
comparisons use stock build_runner 2.16.2. Its supported manifest subset is
checked for byte-identical outputs and incremental, failure, deletion, rename,
and watch behavior. Use auto to retain stock compatibility outside that subset.

Native build and watch commands acquire an exclusive workspace lock through
late fallback; a competing native invocation fails. Direct stock runs,
`--mode dart`, and auto fallback before native startup bypass that lock. Do not
run those concurrently with a native command in the same workspace.

A builder failure leaves native outputs and graph at their last successful
state. The commit is not crash-atomic: interruption or I/O failure during commit
can leave some files changed while the previous graph remains. See the
[recovery guide](docs/compatibility-cleanup.md#safe-recovery) before clearing
state or switching frontends. Successful native builds retain build-start
evidence for existing sources, keeping edits or deletions during actions
visible to the next build or watch cycle. Filtered builds also retain first
worker observations of eligible external sources absent at build start; see
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
