# ADR-0056: package-owned target graph in the generic manifest path

- Status: accepted
- Date: 2026-09-05

## Context

The first generic manifest model selected builders only for the root target.
That was sufficient for a dependency-provided `auto_apply: dependents` builder,
but it did not represent a builder explicitly enabled by a dependency package's
own target. The official `TargetGraph` contains a `package:target` node for
every package target and executes target dependencies before their dependents.

The Rust planner also used the root package as the implicit input scope and
used `builder|input` as its graph key. Both assumptions become incorrect when
the same builder is configured on more than one target or when a dependency
target owns the input asset.

## Decision

- Manifest version 4 includes `package`, `target`, `target_order`, and per-target
  `phase` on every active builder entry. Version 4 also encodes the target SCC
  and the build-runner-compatible phase/member order; see ADR-0057.
- The manifest generator resolves all non-SDK package targets through the
  official `PackageGraph` and `BuildConfig` objects. Explicit target builder
  configuration and the standard `root_package`, `all_packages`, and
  `dependents` auto-apply filters are evaluated against each target package.
- Target dependencies are emitted in the deterministic dependency-first SCC
  order used by build_runner. Within an SCC, the global builder order is
  applied first and the target members are then emitted in the stable SCC
  member order.
- Rust snapshots scan the package roots that own active target builders, while
  tracked asset reads and globs continue to extend the snapshot lazily. Asset
  paths, cache outputs, and worker RPC remain package-aware.
- Action graph keys are scoped as `target|builder|input`, and graph schema 3
  invalidates the previous root-only graph safely.
- Non-root target builders must use `build_to: cache`; source outputs outside
  the root package are kept on the conservative Dart fallback/error boundary.
- A worker is initialized for the package owning the current target. It is
  reused within adjacent phases of that package and restarted at a package
  boundary, so the worker protocol remains generic and does not gain builder-
  specific branches.
- Native watch registers dependency package roots as well as the root package,
  while generated root outputs and build metadata remain filtered as before.

## Consequences

- A dependency package can own a normal, non-optional cache builder without
  requiring a builder-specific Rust implementation.
- The same builder/input pair can be planned independently for multiple
  targets, and dependency target outputs are visible to later actions through
  the existing overlay/cache reader.
- Switching package scope currently costs a worker restart. This is explicit
  and measurable; a resident multi-package worker is a later optimization.
- Optional demand-driven phases, non-root source outputs, post-process
  builders, and multiple build-extension mappings remain outside this generic
  subset. Target cycle details and the dirty-output visibility rule are in
  ADR-0057.

## Verification

`scripts/correctness_arbitrary_dependency_target.sh` compares stock and Rust
for a dependency-owned target and a root target using the same builder. It
checks clean output, no-op, dependency-only change, root-only change, cache
placement, and the two-action target order. Existing arbitrary builder,
package-target, dependency-builder, capture, and watch regressions remain
green. Rust 1.98.1 unit tests pass with the graph schema transition.

`scripts/correctness_target_cycle.sh` compares a same-package two-target SCC
where the same builder is applied to both members. It checks the SCC member
phase order, visibility of the fresh upstream output through the overlay,
no-op, dependent invalidation, and delete-only cleanup.

With Dart SDK 3.13.0, Rust 1.98.1, `JOBS=1`, and Freezed 3.2.3 plus
json_serializable 6.11.2, the generic target-aware path remained
byte-identical to stock and passed clean/no-op/1-file/all-input cases. The
latest single-run wall times were: clean stock/Rust `16.218s`/`14.907s`,
no-op `1.572s`/`0.009s`, 1-file `3.203s`/`1.764s`, and all-input
`3.413s`/`2.204s`. The generic non-root hidden-output filtering is required for
this mixed-package graph because dependency packages can declare source-output
builders that are not visible in the root target's final asset graph.
