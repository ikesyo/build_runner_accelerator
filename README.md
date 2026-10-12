# build_runner_accelerator

An experimental Rust frontend for [build_runner](https://pub.dev/packages/build_runner). Rust plans actions and manages incremental state; a Dart worker runs builders through build_runner APIs.

## Install and run

Add the package to your application:

```bash
dart pub add dev:build_runner_accelerator
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

Use --build-filter to build matching outputs and the producers they need:

```bash
dart run build_runner_accelerator build --build-filter='lib/*.g.dart'
```

Repeat the option or provide comma-separated patterns to select more outputs.
A selected action may write its other declared outputs too. Filtered demand runs
on one worker by default. A filter with no matches succeeds.

Filters limit demand; they do not guarantee that unselected generated files
remain on disk across later builds or watch restarts. Unsupported filter syntax,
builder types, or prior-state transitions use stock in auto and report an error
in rust. See [ADR 0032](docs/adr/0032-native-build-filter-demand-and-output-state.md)
for the selection, dependency, deletion, and failure rules.

## Compatibility and recovery

The native frontend targets build_runner 2.16.2. Its supported manifest subset
is checked against stock for byte-identical outputs and incremental, failure,
deletion, and watch behavior. Use auto to retain stock compatibility outside
that subset.

A builder failure leaves native outputs and graph at their last successful
state. The commit is not crash-atomic: interruption or I/O failure during commit
can leave some files changed while the previous graph remains. See the
[recovery guide](docs/compatibility-cleanup.md#safe-recovery) before clearing
state or switching frontends. Native watch keeps source edits made during an
active build pending for the next cycle.

## Project guides

| If you need to… | See |
| --- | --- |
| Check supported CLI options, modes, and environment controls | [Launcher reference](docs/launcher-and-release.md) |
| Understand build.yaml, --define, release, and named-config behavior | [Configuration guide](docs/configuration.md) |
| Review native build-filter guarantees and limits | [ADR 0032](docs/adr/0032-native-build-filter-demand-and-output-state.md) |
| Understand Rust/Dart responsibilities and IPC | [Protocol v1](protocol/v1.md) and [ADR index](docs/adr/README.md) |
| Contribute or run correctness checks | [Development guide](docs/development.md) |
| Review measured performance | [Benchmarks](docs/benchmarks.md) |
| Check release status and remaining work | [Roadmap](docs/roadmap.md) |

For updates that affect existing workspaces, use the
[compatibility cleanup guide](docs/compatibility-cleanup.md).
