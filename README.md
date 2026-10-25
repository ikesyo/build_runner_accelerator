# build_runner_accelerator

A Rust-accelerated frontend for [build_runner](https://pub.dev/packages/build_runner).
Rust plans actions and manages incremental state; a Dart worker runs builders
through build_runner APIs.

Requires Dart >=3.11.0 <4.0.0 and build_runner >=2.15.3 <2.18.0.
Use 2.17.1 for the 2.17 line; 2.17.0 requires the retracted build 4.1.0.
Shared-library builders (`adds_to_library: true`) require the follow-up native shared-part support.
Support applies to the validated configurations in the
[compatibility inventory](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/compatibility-probes.md), not every feature of a
named builder. Read the [compatibility contract](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/launcher-and-release.md#1x-compatibility-contract)
before adopting it.

## Performance

In user-reported measurements of a real-world Flutter application,
**cache-warm clean builds were 2.6× faster** than stock build_runner
(repeat count and variability not reported).
Across two environments, clean builds including AOT compilation with analyzer
caches cleared were approximately **1.1× faster**, and no-op builds were
**2.2–4.1× faster**.

Our 500-feature mixed-builder benchmark measured **1.2× faster clean builds**
and **4.6× faster warm no-op builds**. These are Linux measurements;
see [benchmarks](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/benchmarks.md) for cache definitions, conditions and results.

## Installation

The current package version is `0.16.1`.

Add the package to your application:

```bash
dart pub add dev:build_runner_accelerator:^0.16.1
```

Or add it to `pubspec.yaml`:

```yaml
dev_dependencies:
  build_runner_accelerator: ^0.16.1
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

## Before you build

The launcher downloads and verifies a matching native binary. Published targets
are Linux x64/arm64, macOS arm64, and Windows x64/arm64; platform limits are in
[binary selection](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/launcher-and-release.md#binary-selection-and-integrity).
Unsupported requests or an unavailable binary fail explicitly. The accelerator
never starts stock build_runner; run `dart run build_runner build` directly
when needed. Stop native commands before running stock in the same workspace,
and follow the [recovery guide](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/compatibility-cleanup.md#safe-recovery)
before returning to native.

Builder failures leave outputs and the graph at their last successful state.
Interrupted publication is recovered before the next build/watch; preserve any
pending undo evidence. Publication is not a simultaneous atomic snapshot and
has no power-loss durability guarantee. See [interrupted publication](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/compatibility-cleanup.md#interrupted-publication).

## Common options

```bash
# Build selected outputs and their dependencies.
dart run build_runner_accelerator build --build-filter='lib/*.g.dart'

# Verify generated outputs without changing them (exit 1 on differences).
dart run build_runner_accelerator build --only-check

# Retain manual output edits until their producer reruns.
dart run build_runner_accelerator build --keep-modified-outputs
```

Output policies are build-only and mutually exclusive. Filters and policies
have compatibility limits; see the [CLI reference](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/launcher-and-release.md).
For `build.yaml`, named configs and `--define`, see [configuration](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/configuration.md).
Upgrading from an older version? See the [migration guide](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/compatibility-cleanup.md).

## Documentation and contributing

The [documentation index](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/README.md) separates usage, contribution guides,
and historical evidence. Start with [development](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/development.md) to
contribute, [benchmarks](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/benchmarks.md) for measured performance, or the
[roadmap](https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/roadmap.md) for remaining release gates.
