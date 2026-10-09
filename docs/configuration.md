# Native configuration compatibility

The supported stock window is `build_runner >=2.16.2 <2.17.0`; the differential
fixture uses the resolved stock package in the same SDK/pub cache as native.
The implementation follows `BuildRunnerCommandLine`,
`BuildOptions._parseBuilderConfigOverrides`, `findBuildConfigOverrides`,
`BuilderDefinitions.load`, `BuildPhaseCreator._createOptions`, and
`BuildSeries._isBuildConfiguration` in 2.16.2.

## CLI and resolution

Build/watch/prewarm (including detached prewarm)
resolve `--define`, `--release`, `--no-release`, and `--config` consistently.
Long options accept separate values and `=VALUE`. `-r` and `-c NAME` are
supported, including attached `-cNAME` and grouped `-rd` / `-dr` (also
repeated flags). Groups containing `d` retain its build/watch-only acceptance.
Stock permits a value-taking abbreviation only as the first
character: `-rcNAME` is invalid. `-c=NAME` selects the literal name `=NAME`.
Config names may contain `/` or `\`: stock first constructs
`build.<name>.yaml`, replaces backslashes with `/`, then normalizes POSIX
segments as an AssetId inside the root package. Thus `-cdir/name` reads
`build.dir/name.yaml`, while `-cdir/../name` reads `name.yaml`; this is not an
arbitrary config-file-path option. Names resolving outside the package fail.
Only the final repeated config value is resolved. Prewarm retains its existing
rejection of unsupported CLI syntax; stock has no prewarm command.
For build/watch, a `--` separator, positional build directories and other
unsupported options still select stock as a whole.
Values remain stock values even if they resemble accelerator flags.

Development is the default. Release/config repetition is last-wins. Define is
repeatable without comma splitting; split only at the first two `=` signs.
Normalize builder names with build_config (including the legacy `|` separator).
Decode valid JSON, otherwise retain the exact string, including an empty value.
Duplicate normalized builder/option pairs fail; unknown builders have no
application and do not enable builders. Build/watch syntax errors and missing
selected files detected before native setup select stock in auto. Prewarm
rejects unsupported CLI syntax; a missing selected file skips auto prewarm with
a diagnostic. Root-dependent alias errors discovered during resolution select
stock at the manifest boundary. Rust errors explicitly. Other config-file
errors are checked during manifest generation. Stock exit codes are preserved;
no native actions run after a failed or unsupported resolution.

Option maps retain Dart insertion order, including nested JSON objects, across
manifest and IPC transport. Every map is merged shallowly, from lowest to
highest precedence:

1. Builder defaults `options`, then `dev_options` or `release_options`.
2. Target `options`, then target mode options.
3. Root `global_options`, then global mode options.
4. CLI defines, for every selected application of the builder.

Builder enablement, sources and generate_for come from the selected target
configuration, not defines or release mode. BuilderOptions.isRoot retains the
configured package's root bit. Probing uses the same options as build actions,
so an option-dependent output mapping is preserved.

Root-level `<package>.build.yaml` files replace that package's BuildConfig.
`build.NAME.yaml` then replaces the root configuration, including targets,
global options and triggers; it is not merged over build.yaml. Factory
definitions still come from ordinary/package override configs, matching stock's
separate definition loader. Named definitions cannot replace factories.
Ambiguous multiple package override filenames, unsupported target/builder/trigger
shapes, and configurations with no supported selected builders remain full
fallback/error cases. Malformed or missing config files are never partially
applied. The existing manifest subset remains the boundary.

## Cache and watch behavior

The manifest/probe identity includes the original supported CLI vector,
package configuration, lockfile, all packages' build.yaml contents, root package
override filenames/contents, and the selected named file (including absence).
Switching modes/configs/defines or editing/removing/restoring configuration
regenerates the manifest and invalidates the private action graph via its
manifest signature. Repeating an unchanged request remains a no-op.
An empty application list retains supported builder definitions so obsolete
outputs from previously enabled builders can be deleted. Disabling every
builder, repeating that build and enabling them again follows stock's output
lifecycle; cached manifests from before this rule are invalidated.
Inactive multi-factory builders retain per-factory cleanup definitions without
instantiating their factories; active applications still require runtime probes.

Worker instances are scoped to configured builder applications and receive
resolved options on each build request. Watch replaces the resident pool when the manifest identity
changes, ensuring that pinned JIT/AOT artifacts cannot retain an old catalog.
Stock watches build.yaml, package overrides and the selected named config and
reloads the build plan; a changed factory/script may require bootstrap restart.
Native re-resolves value-only configuration changes and reselects the worker.
Stock 2.16.2 compares the raw `build.<name>.yaml` spelling when deciding whether
watch events reload configuration, even though loading uses a normalized
AssetId. Native preserves that behavior: when backslashes or dot segments
change the spelling, edits to that selected file keep the resident options
(including on a subsequent input edit) until a recognized configuration event,
such as a `build.yaml` edit, reloads the plan. A separate build reads the current
normalized file immediately. Canonical nested names reload directly, including
selected files under directories such as `target` that native otherwise ignores.
Stock attributes nested-package events to the deepest package: if the selected
root config physically lies in a dependency package, its edit also keeps the
resident root plan until a recognized configuration event.
Changes to builder applications, mappings, sources, filters or phase topology
are a conservative watch boundary: auto hands the complete invocation to a new
stock watch; rust terminates before actions with an explicit error. Stock 2.16.2
resident reload can differ from a fresh build for such changes (the fixture
records deletion without new output after a mapping/enablement transition).
Native does not partially reproduce that transition. The fresh stock process
uses the actual filesystem and its own graph, including stock retention of
files previously emitted only by native; it is a full handoff, not a resident
stock reload emulation. Other unsupported changes
also switch auto to stock watch as a whole or terminate rust. Unselected named files do not change the
resolved configuration. Native may schedule an extra no-op for irrelevant file
events under its existing filesystem watcher.

AOT and kernel artifacts compile executable code, not BuilderOptions. They may
be shared between settings when the generated catalog source and all compiler
inputs agree; resolved options are supplied at runtime. The AOT key includes
SDK, worker source, package identity, lockfile and ordinary manifest inputs;
dependency digests validate restoration. A catalog change changes worker source
and prevents reuse. Early AOT uses the same settings for catalog selection and
the authoritative generator checks its source before accepting it. Generator
kernels remain code-only caches and re-read settings/configs at execution.
Analyzer caches contain SDK/analysis data, not builder configuration/output.
No settings-dependent outputs or action graphs are shared through these caches.

`scripts/correctness_settings.sh` compares generated bytes, retained/removed
outputs and errors with stock across initial/no-op/settings/restored builds,
configuration overrides, runtime mappings, watch reloads, JIT/AOT/prewarm,
frontend modes and early/late fallback. Watch package attribution includes
example apps with ancestor path dependencies as well as configs inside child
dependencies: only the deepest containing package owns the event.
`test/build_settings_test.dart` also
compares option parsing with the actual stock CLI and BuildOptions APIs.
