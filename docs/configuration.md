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

Options merge by top-level key. Higher rows replace lower rows; nested maps are
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
applied. `auto` routes the whole invocation to stock; `rust` reports an error before
native actions. Stock diagnostics and exit status are preserved.

## Watch and cache behavior

Configuration identity includes supported CLI settings and the relevant
package configs, `pubspec.lock`, package `build.yaml` files, root override
files, and the selected named config (including its absence). A settings change
regenerates the manifest and invalidates the private action graph. Runtime filters and
worker compile mode do not change configuration identity.

Value-only changes can reload during native watch. Changes to builder
applications, mappings, sources, or phase topology hand the whole watch to
stock in auto and stop with an error in rust. The worker pool is replaced when
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

## Checks

`scripts/correctness_settings.sh` compares outputs, deletion, errors, and watch
reloads with stock. `test/build_settings_test.dart` compares option parsing
with stock CLI and `BuildOptions` behavior.
