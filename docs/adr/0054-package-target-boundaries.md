# ADR-0054: Package/target boundary and output conflict semantics

- Status: accepted
- Date: 2026-09-05

## Context

The dynamic manifest is resolved from the official `PackageGraph` and
`BuildConfig` for every package, but the current Rust planner scans and
executes the root package target. A builder declared by a direct dependency
can still be part of that root target when `auto_apply: dependents` selects it.
The planner must also preserve build_runner's failure boundary when two
selected actions claim the same output AssetId.

## Decision

The current generic subset supports a direct dependency package's builder when
all of the following hold:

- its import is a `package:` URI resolvable from the root package;
- its `auto_apply` relation selects it for the root target;
- its default or root-target `generate_for` is representable by the manifest;
- its inputs and outputs remain in the root target's supported suffix/path
  subset.

The root target's source include/exclude remains the final candidate filter.
Required-input and phase ordering are planned from the resolved dependency
builder metadata, so a cache output from an earlier dependency builder can be
read by a later root-target action through the existing overlay/cache path.

At the time of this decision the implementation did not claim full
multi-package execution. The follow-up in ADR-0056 adds dependency-owned
targets, target-scoped action keys, and package-aware snapshot/asset scanning
for the non-optional cache-builder subset. ADR-0057 then adds target SCC phase
semantics for the same generic subset; non-root source outputs remain outside
the compatibility boundary.

Before dirty checking or worker startup, Rust rejects any duplicate output
AssetId among the planned actions. This includes duplicate outputs declared by
one action and outputs claimed by different builder actions. The error is
intentional: stock build_runner rejects the same graph with an `outputs
collide` diagnostic, and accepting the graph in Rust would make the result
depend on execution order or silently overwrite a generated file.

## Consequences

- A dependency-provided builder can use the same generic manifest, worker,
  phase, overlay, and incremental machinery as a root-package builder.
- Output conflicts fail before any worker action or atomic commit, leaving
  existing generated files untouched.
- Supporting further target semantics requires extending snapshot, asset
  lookup, graph keys, and commit paths together; it is not added as a
  package-name special case. See ADR-0056 and ADR-0057 for the target-graph
  stages.
- Popular builders remain validation fixtures for the generic path rather than
  being added to a built-in Rust catalog.

## Verification

`scripts/correctness_arbitrary_package_target_builder.sh` compares a
dependency package's `auto_apply: dependents` seed/summary chain against
stock for clean, no-op, target-source exclusion, and input-change cases.
`scripts/correctness_arbitrary_builder.sh` with
`CASE_FILTER=output-conflict` verifies the duplicate-output failure boundary.
