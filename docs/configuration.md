# Native configuration compatibility

Native configuration is compared with stock `build_runner` 2.16.2. The evidence
comes from its `BuildRunnerCommandLine`, `BuildOptions`, `BuildConfig`, and
`BuildPhaseCreator` implementations. This is a version-specific compatibility
target, not a promise about later private APIs.

## Command-line settings

| Setting | Resolution |
| --- | --- |
| `--define builder=key=value` | Repeatable. Split at the first two equals signs; decode valid JSON, otherwise keep the exact string. |
| `--release` / `--no-release` | Select release or development options. Development is the default; the last flag wins. |
| `--config NAME` | Use `build.NAME.yaml` for root targets, global options, and triggers. The last repeated name wins. |
| `-r`, `-c NAME`, `-cNAME`, `-rd` / `-dr` | Use stock spellings and grouping rules. Config names are normalized as package asset paths, not arbitrary file paths. |

Builder names use `build_config` normalization: an unqualified name means
`name:name`, while `:builder` refers to a builder in the current package. Repeated
normalized builder/key pairs are errors. Defines configure selected builders;
they do not enable disabled builders.

## Option precedence and files

Options merge by top-level key. Later rows override earlier rows; nested maps are
not recursively merged.

| Order | Source |
| --- | --- |
| 1 | Builder defaults, then builder development/release defaults |
| 2 | Target options, then target development/release options |
| 3 | Root global options, then root global development/release options |
| 4 | CLI `--define` values |

The root package's `<package>.build.yaml` replaces its `BuildConfig`. A selected
`build.NAME.yaml` replaces root targets, global options, and triggers; builder
definitions still come from `build.yaml` and package overrides.

Malformed, missing, ambiguous, or unsupported configuration is not partially
applied. The accelerator reports an error before native actions.

## Package source sets

Root target defaults use stock's in-build source list (`lib/**`, `test/**`,
`example/**`, and the other standard paths), plus `additional_public_assets`.
An arbitrary nested dependency directory such as `dep/` is outside those
root defaults. Dependency assets still use their own package ID even when
no builder is enabled there. Source listing, explicit reads and globs respect
all target source sets and dependency public-asset restrictions.
Watch ignores events outside those source sets unless they affect build
configuration or graph-tracked assets.

An explicit root `sources: ['**']` includes nested files under root-relative
IDs too: stock also generates root-owned outputs in that case. There is no
unconditional deepest-package ownership rule for one-shot builds.

Native supports broad sources such as `['lib/**', 'dep/**']`. Source sets
admitting `.dart_tool/build/**` or `.dart_tool/build_runner_accelerator/**`
are rejected before actions: stock can consume
its own prior artifact tree as root inputs, while native has a different
private artifact layout. For `**`, exclude `.dart_tool/**` to avoid this
implementation-directory boundary. Other eligible hidden files are included.

Native watch requires source sets that cannot reach another configured package
root. Stock watches only the deepest package identity, retaining different
parent-alias source/cache evidence until restart; native snapshots cannot
reproduce that history. Potentially overlapping watch inputs therefore
fail before actions. Literal subtree exclusions such
as `exclude: ['.dart_tool/**', 'dep/**']` allow native watch. The prefix check is
conservative when more complex exclusions cannot prove that the subtree is excluded.

## Watch and cache behavior

Configuration identity includes supported CLI settings and the relevant
package configs, `pubspec.lock`, package `build.yaml` files, root override
files, and the selected named config (including its absence). A settings change
regenerates the manifest and invalidates the private action graph. Runtime filters and
worker compile mode do not change configuration identity.

Value-only changes can reload during native watch. Changes to builder
applications, mappings, sources, or phase topology stop watch with an error. The worker pool is replaced when
the resolved manifest changes.

Stock 2.16.2 watches the raw named-config spelling even though it normalizes the
file path when loading. A name containing backslashes or `.` segments may
therefore stay stale in a running watch until another recognized config event;
a separate build reads the current normalized file. Use canonical config names
for predictable watch reloads.

The worker AOT and kernel caches hold executable code, not resolved options.
Options are supplied at runtime, and settings-dependent output graphs are not
shared through those caches. See [ADR 0031](adr/0031-native-build-settings.md)
for the cache boundary and [ADR 0032](adr/0032-native-build-filter-demand-and-output-state.md)
for filtered-build configuration transitions.

## Input extension mappings

An ordinary Builder's empty input key (`buildExtensions['']`) matches every
eligible input asset, including extensionless files. It appends the declared
output suffix: `lib/model.dart` with `.out` becomes `lib/model.dart.out`.
Regular and empty-key mappings on one Builder produce the union of outputs;
duplicate output AssetIds remain errors.

Target sources, `generate_for`, package visibility, source/cache placement and
later-phase visibility still apply. This supports the existing simple output
suffix subset for static and runtime-probed ordinary Builders; it does not
extend post-process or workspace support. Dart emits `input_match: "all"`
with an empty `input_suffix`; Rust consumes that normalized shape.

The [build 4.0.11 contract](https://github.com/dart-lang/build/blob/build-v4.0.11/build/lib/src/builder.dart)
and its [expected-output implementation](https://github.com/dart-lang/build/blob/build-v4.0.11/build/lib/src/expected_outputs.dart)
are the upstream reference. `fixtures/empty_input_mapping_app` currently pins
build_runner 2.16.2; `scripts/correctness_empty_input_mapping.sh` and
`scripts/watch_smoke_empty_input_mapping.sh` cover lifecycle, filtering,
collisions, jobs 1/2, failure recovery and watch. Performance is unmeasured.

## Checks

`scripts/correctness_settings.sh` compares outputs, deletion, errors, and watch
reloads with stock. `test/build_settings_test.dart` compares option parsing
with stock CLI and `BuildOptions` behavior.
