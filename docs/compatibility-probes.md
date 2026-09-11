# Compatibility probes

This is the current inventory of external build_runner workloads that have
been probed against the native frontend. A successful probe means that the
selected target completed and its generated outputs matched stock
`build_runner`; it is not a claim that every builder in the repository is
supported.

## Current inventory

| Workload | Result | Classification | Notes |
| --- | --- | --- | --- |
| `dart-lang/build` `built_types/built_value_example` at `e5772728` | Passed after this change; regression fixture added | Supported target shape | A clean full-example comparison matched stock outputs. `built_value_generator:built_value` uses `run_only_if_triggered: true`; stock skips inputs such as `bin/example.dart`, so a declared `.built_value.g.part` is not always emitted. The native build now accepts an empty result from any normal builder and removes stale outputs when a previously generated output is no longer emitted. |
| `google/json_serializable.dart` example | Passed | Supported target shape | Clean, AOT-warm, incremental, and output-byte comparisons passed in the earlier probe. |
| `fixtures/freezed_app` (`freezed 4.0.1`, `json_serializable 6.14.1`) | Passed | Current stack fixture | The lockfile resolves `build_runner 2.16.1` with Analyzer 14.3.0. Clean, incremental, failure, deletion, rename, watch, and byte-identical stock/native comparisons are covered. |
| `fixtures/riverpod_app` (`riverpod_generator 4.0.9`, `freezed 4.0.1`, `json_serializable 6.14.1`) | Passed | Current stack fixture | The lockfile resolves `build_runner 2.16.1` with Analyzer 14.3.0. Provider, Freezed, and JSON outputs are compared across clean, incremental, failure, deletion, watch, and byte-identical stock/native cases. |
| Conduit Flutter target | Passed | Supported subset | Isolated Freezed/JSON target completed with byte-identical outputs. |
| API Dash `har` target | Passed after narrowing | Supported subset | The initial probe expected a Freezed output for an input outside that builder's effective `generate_for`; the narrowed target completed with matching outputs. |
| Invoice Ninja model target | Passed | Supported subset | Isolated Freezed/JSON target completed with byte-identical outputs. |
| Official Conduit stamp-only target | Passed | Supported subset | `conduit_build_runner`'s `stamp_builder` completed. |
| Official Conduit full builder set | Not supported | Conservative fallback | `registry_builder` is outside the current manifest/worker subset. |
| Drift `examples/app` / `examples/with_built_value` | Not supported | Conservative fallback | The probe stopped before native generation on `build_web_compilers` / `drift_dev:analyzer`, which are outside the current subset. |

Some full repository roots also could not be resolved under the probe's
pub.dev dependency constraints. Those are dependency-resolution limitations,
not native builder failures, and should be re-probed independently after the
workload has a reproducible lockfile.

## Follow-up order

1. Keep the `built_value` fixture in the normal full correctness suite.
2. Add explicit trigger metadata/evaluation only if invoking a non-triggered
   builder proves to be observably different from stock or causes a builder to
   fail when it receives an input that stock would skip.
3. Investigate `registry_builder`, `drift_dev:analyzer`, and
   `build_web_compilers` as separate compatibility additions; do not encode
   them as builder-name special cases in the Rust planner.
