# Compatibility probes

This is the current inventory of external build_runner workloads that have
been probed against the native frontend. Runtime expected-output mappings are
captured by the Dart manifest boundary; Rust consumes only their normalized
shape. A successful probe means that the
selected target completed and its generated outputs matched stock
`build_runner`; it is not a claim that every builder in the repository is
supported.

## Current inventory

| Workload | Result | Classification | Notes |
| --- | --- | --- | --- |
| `dart-lang/build` `built_types/built_value_example` at `e5772728` | Regression fixture | Supported target shape | `built_value_generator:built_value` is a normal Builder: the static build.yaml mapping is `.dart` to `.built_value.g.part`, `build_to: cache`, and `source_gen\|combining_builder` consumes `.g.part` via `required_inputs`; `part_cleanup` is a separate post-process builder. The manifest uses the validated static mapping for this single-factory, no-option case; option-dependent and multi-factory applications use the instantiated mapping probe. Its official import and `SerializersFor` triggers are normalized from Dart and evaluated by the resident worker. Source/cache output visibility and empty-result stale cleanup remain preserved. |
| `google/json_serializable.dart` example | Passed | Supported target shape | Clean, AOT-warm, incremental, and output-byte comparisons passed in the earlier probe. |
| `fixtures/freezed_app` (`freezed 4.0.1`, `json_serializable 6.14.1`) | Passed | Current stack fixture | The lockfile resolves `build_runner 2.16.1` with Analyzer 14.3.0. Clean, incremental, failure, deletion, rename, watch, and byte-identical stock/native comparisons are covered. |
| `fixtures/riverpod_app` (`riverpod_generator 4.0.9`, `freezed 4.0.1`, `json_serializable 6.14.1`) | Passed | Current stack fixture | The lockfile resolves `build_runner 2.16.1` with Analyzer 14.3.0. Provider, Freezed, and JSON outputs are compared across clean, incremental, failure, deletion, watch, and byte-identical stock/native cases. |
| `fixtures/multi_mapping_builder_app` | Regression fixture | Supported target shape | The static build.yaml suffix is intentionally overridden by a resolved option at runtime (`.runtime` vs `.multi`), while the anchored special-path output remains literal. Clean, no-op, change, rename, and deletion compare the resulting output union; the native side runs with two jobs to exercise concurrent action planning. |
| `fixtures/lifetime_builder_app` | Passed | Supported target shape | With `--jobs 1`, two source builders run in separate phases with one resident worker. Builder instance state and a shared `Resource` remain stable across four inputs, and the second phase reads the first phase's generated assets. |
| `fixtures/applies_builder_app` | Passed | Supported target shape | An `applies_builders` consumer is scheduled after its producer phase; stock/native generated outputs match across clean, no-op, change, rename, and deletion cases. |
| `fixtures/optional_builder_app` | Regression fixture | Supported target shape | A normal `is_optional` builder is skipped when undemanded and is run on demand for both secondary reads and primary-input consumers; clean, incremental, failure recovery, deletion, rename, and watch cases compare stock/native outputs. |
| `fixtures/trigger_builder_app` | Regression fixture | Supported trigger shape | Compares stock/native import, annotation, combined, part-annotation, generated-primary, and `is_optional` + `run_only_if_triggered` cases. It covers trigger transitions, stale-output cleanup, generated-input changes, deletion, rename, failure recovery, and two-job execution; the paired watch probe covers trigger changes and resident worker lifetime. |
| `fixtures/drift_app` (`drift 2.34.4`, `drift_dev 2.34.6`) | Passed | Supported target shape | `drift_dev`'s multiple factories are expanded using their runtime `buildExtensions`, including generated schema metadata, Dart parts, and cleanup of temporary artifacts. Clean, no-op, incremental, deletion, and byte-identical stock/native comparisons pass. |
| Conduit Flutter target | Passed | Supported subset | Isolated Freezed/JSON target completed with byte-identical outputs. |
| API Dash `har` target | Passed after narrowing | Supported subset | The initial probe expected a Freezed output for an input outside that builder's effective `generate_for`; the narrowed target completed with matching outputs. |
| Invoice Ninja model target | Passed | Supported subset | Isolated Freezed/JSON target completed with byte-identical outputs. |
| Official Conduit stamp-only target | Passed | Supported subset | `conduit_build_runner`'s `stamp_builder` completed. |
| Official Conduit full builder set | Not supported | Conservative fallback | `registry_builder` is outside the current manifest/worker subset. |
| Drift `examples/app` / `examples/with_built_value` | Not supported | Conservative fallback | The full examples still include `build_web_compilers` and `drift_dev:analyzer`, which are outside the current subset. The focused `fixtures/drift_app` probe covers the compatible `drift_dev` factory/output path. |

Some full repository roots also could not be resolved under the probe's
pub.dev dependency constraints. Those are dependency-resolution limitations,
not native builder failures, and should be re-probed independently after the
workload has a reproducible lockfile.

## Follow-up order

1. Keep the `built_value` fixture in the normal full correctness suite.
2. Investigate `registry_builder`, `drift_dev:analyzer`, and
   `build_web_compilers` as separate compatibility additions; do not encode
   them as builder-name special cases in the Rust planner.

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
the supported normalized subset. `--mode auto` falls back to stock Dart
`build_runner`; `--mode rust` reports an explicit unsupported error.
