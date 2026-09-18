# Empty input extension mappings

## Scope

This change targets ordinary `Builder`s whose `buildExtensions` contains the
empty input key (`'': [...]`). It is deliberately separate from an empty
output list (`'.dart': []`), which is already supported by the accelerator.

The compatibility boundary is the pinned dependency set in this repository:

- `build_runner` 2.16.1
- `build` 4.0.11
- `build_config` 1.3.3
- upstream source commit `5e25e60f55686be9d6eec2aaa448802ae1a17a40`

## Official semantics

In `build` 4.0.11, `Builder.buildExtensions` documents an empty input key as
matching **all input assets**. It is not an extensionless-file selector, a
`.dart` alias, or a wildcard string. The normal suffix replacement still
applies, with a zero-length input suffix: for example,
`lib/model.dart -> lib/model.dart.empty_mapping.out`, and
`lib/README -> lib/README.empty_mapping.out`.

The official expected-output implementation parses each mapping independently.
Consequently, a regular mapping and an empty-key mapping on the same Builder
are both considered, and their outputs are the union of the two mappings.
Duplicate output AssetIds remain invalid, including collisions between actions.

The normal build-plan rules continue to determine the candidate assets:

- `generate_for` filters the current input asset.
- target sources filter the primary input; a generated input is anchored back
  to the original primary input before this check.
- package boundaries and public input visibility are established by
  `PackageGraph`, `BuildConfig`, and build_runner's target configuration.
- `build_to: source` publishes the declared output in the source tree;
  `build_to: cache` publishes it in the asset graph/cache view. In either case,
  later phases can consume the output only after the producing phase commits.

## Design

Dart remains the source of truth. Manifest normalization represents an empty
input key with the explicit mapping kind `input_match: "all"` and retains its
empty `input_suffix`. It is never rewritten to `.dart`, `.*`, or another
synthetic suffix. Runtime factory probes use the same normalized mapping shape.

Rust only consumes that manifest representation. The planner adds an explicit
`all` match branch and derives an output by appending the output suffix to the
complete `AssetId` path. Existing suffix, exact, and capture mappings retain
their current code paths and validation. The mapping kind is included in the
manifest version/config identity so an older planner cannot silently reuse a
graph with different matching semantics.

## Supported subset for this change

- ordinary Builders, including static and runtime-probed mappings;
- one or more empty-key outputs;
- regular and empty-key mappings combined in one Builder;
- source and cache outputs;
- existing target-source, `generate_for`, required-input, trigger, optional,
  overlay, stale-output, collision, and downstream-phase semantics;
- the existing simple output-suffix subset used by regular mappings.

Unsupported mapping shapes continue to be rejected by manifest normalization
or Rust manifest validation. In `--mode auto` this causes a pre-generation
fallback to stock Dart build_runner; in `--mode rust` it is an explicit
unsupported error. No package- or Builder-name-specific Rust branch is added.
Post-process Builders, Drift-specific behavior, workspace semantics, and other
unrelated compatibility extensions remain outside this change.

## Validation plan

The generic fixture exercises extensionless, `.dart`, `.drift`, and multiple
inputs, including a regular-plus-empty mapping and a downstream generated
input. The stock and native runs compare action counts, paths, inventories,
contents, source/cache placement, stale cleanup, filtering, jobs 1/2, watch,
and failure recovery. Cache-root paths and implementation-specific diagnostics
are excluded from byte-for-byte comparisons. Performance is not measured for
this change.

## Pinned upstream references

- [`Builder.buildExtensions`](https://github.com/dart-lang/build/blob/build-v4.0.11/build/lib/src/builder.dart)
- [`expected_outputs.dart`](https://github.com/dart-lang/build/blob/build-v4.0.11/build/lib/src/expected_outputs.dart)
- [`BuildStepPlan`](https://github.com/dart-lang/build/blob/build_runner-v2.16.1/build_runner/lib/src/build_plan/build_step_plan.dart)
- [`BuildPhaseCreator`](https://github.com/dart-lang/build/blob/build_runner-v2.16.1/build_runner/lib/src/build_plan/build_phase_creator.dart)
- [`BuilderDefinition`](https://github.com/dart-lang/build/blob/build_config-v1.3.3/build_config/lib/src/builder_definition.dart)
