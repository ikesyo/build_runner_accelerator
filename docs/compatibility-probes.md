# Compatibility inventory

Support is scoped to the tested configuration and dependency solution, not an
entire builder package or upstream repository. Tracked fixture lockfiles and
comparison scripts define reproducible coverage. The
[public contract](launcher-and-release.md#1x-compatibility-contract) defines the
guarantees; this inventory points to evidence rather than repeating them.

## Tracked workloads

Unless noted otherwise, scripts compare stock/native output sets and bytes.
See [development](development.md#correctness-and-ci) for focused commands.

| Workload | Validated scope and evidence |
| --- | --- |
| Freezed + JSON | `fixtures/freezed_app`: Freezed 4.0.1, JSON Serializable 6.14.1; lifecycle, failure, deletion, rename and watch comparisons |
| Riverpod + Freezed + JSON | `fixtures/riverpod_app`: Riverpod Generator 4.0.9; mixed generation and watch comparisons |
| Built Value | `fixtures/built_value_app`: cache parts, combining builder, triggers and stale-output cleanup |
| Generic mappings | `fixtures/multi_mapping_builder_app`, `fixtures/arbitrary_builder_app` (capture probe), `fixtures/empty_input_mapping_app`: runtime mappings, literal suffixes, capture and all-asset empty-key mapping; see [mapping semantics](configuration.md#input-extension-mappings) |
| Builder lifetime and phase ordering | `fixtures/lifetime_builder_app`, `fixtures/applies_builder_app`: resident Builder/Resource lifetime and generated-input visibility |
| Filtered demand | `fixtures/build_filter_app`: selection, dependencies, globs, transitions and explicit rejection; [ADR 0032](adr/0032-native-build-filter-demand-and-output-state.md) |
| Optional builders and triggers | `fixtures/optional_builder_app`, `fixtures/trigger_builder_app`: lazy demand and trigger transitions; [trigger rules](#trigger-semantics-boundary) |
| Optional + post-process cleanup | [Fixture guide](../fixtures/optional_cleanup_app/README.md): source/cache lifecycle and watch; [ADR 0038](adr/0038-optional-post-process-demand.md) |
| Drift monolithic | `fixtures/drift_app`: Drift 2.34.4 / drift_dev 2.34.6, runtime factory/output mappings |
| Drift analyzer/modular/not_shared | [Fixture guide](../fixtures/drift_analyzer_app/README.md): isolated official chains, resolver APIs, complete cleanup set, failures and watch |
| Conduit registry, published constraints | [Stock-only fixture](../fixtures/registry_builder_app/README.md): Conduit 6.0.0/7.0.0 require Analyzer 12 and cannot resolve in the native window; no native equality claim |
| Conduit registry, override | [Override fixture](../fixtures/registry_builder_override_app/README.md): Conduit 7.0.0 with fixture-only Analyzer 14.5.0 override; virtual inputs, ordered enumeration, lifecycle, failure and watch. Does not establish an override-free solution or other generator support |
| Web compiler dart2js | [Fixture guide](../fixtures/build_web_compilers_app/README.md): published 4.8.12, single package, dev, `-O1`, filtered outputs and AOT watch |
| Web compiler DDC | [Fixture guide](../fixtures/build_web_compilers_ddc_app/README.md): same compiler version, single root, dev/AMD, hot reload disabled; public artifacts and AOT watch |
| FVM root CLI | [Pinned replay](probes/fvm/README.md): introduced dependency solution with dart_mappable_builder 4.10.0 / build_version 2.2.1, initial/no-op/edit/watch bytes. Excludes the old upstream lock, other commits, nested projects and Flutter runtime tests |
| SDK/dependency boundaries | [SDK lifecycle](development.md#sdk-lifecycle-comparison) and [dependency review](dependency-window-review.md): Resolver-based generation at minimum/current resolutions and older-runner adapter coverage |

Full Drift examples, other Conduit generators, broader web compiler modes and
multi-package upstream workspaces remain unvalidated. A dependency-resolution
failure is separate from a native execution failure. Minimum-SDK coverage does
not establish that every listed published builder resolves on that SDK.
Compatibility work on Drift and empty-key mappings has no measured speed claim.

## Historical external probes

Earlier selected targets passed for the JSON Serializable example, Conduit
Flutter Freezed/JSON, API Dash `har` (after narrowing `generate_for`), Invoice
Ninja models and Conduit's stamp builder. These spot checks are not maintained
whole-project regression guarantees; use the tracked workloads above when
assessing current adoption. Additional coverage is tracked in the [roadmap](roadmap.md).

## Trigger semantics boundary

The trigger implementation follows the current `build_runner` 2.16.x
implementation in
[`build_triggers.dart`](https://github.com/dart-lang/build/blob/875fb843e2e20e8f34e1020be8e7141ac54d7ddc/build_runner/lib/src/build_plan/build_triggers.dart)
and `_allowedByTriggers` in `build.dart`:

- `BuildTriggers.fromConfigs` is called over every package config, so
  top-level trigger declarations are aggregated package-wide.
- The supported normalized forms are `import <package-relative-uri>` and
  `annotation <name>`. Imports inspect only the primary input; annotations
  inspect the primary input and readable parts.
- The primary input and readable parts consulted by trigger evaluation are
  recorded in the action dependency set. Trigger configuration also contributes
  the official trigger digest to the manifest/config identity.
- `run_only_if_triggered` remains a normal action gate. Its `not_triggered`
  result is kept distinct from the absent/unused state used by optional lazy
  demand. The combination of `is_optional` and `run_only_if_triggered` is
  therefore preserved.

Invalid trigger configuration and post-process trigger definitions are outside
the supported normalized subset. Unsupported requests fail explicitly.
