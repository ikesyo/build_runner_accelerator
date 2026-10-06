# ADR 0028: Exclude analyzer 14.5 until stock build_runner is compatible

- Status: Accepted
- Date: 2026-10-06
- Updates: ADR 0007 (analyzer upper bound only)

## Context

analyzer 14.4.0 retains the deprecated compatibility setter for
`AnalysisOptionsImpl.contextFeatures`. In 14.5.0 the property is final;
clients must configure `AnalysisOptionsBuilder` and call `build()`.
The worker and prewarm now use that builder, including an import compatible
with analyzer 13.3.0 and explicit non-package feature configuration.

Stock `build_runner 2.16.1` still uses the removed setter in
`lib/src/build/resolver/resolvers_impl.dart:82`. With analyzer 14.5.0,
`dart run build_runner --help`, stock builds/watch, and tests importing that
resolver fail to compile. The latest published build_runner is still 2.16.1
as of 2026-10-06. Upstream main has migrated to the builder, but its unreleased
2.16.2-wip line includes additional dependency and private API changes.

## Decision

Temporarily narrow the direct analyzer constraint to `>=13.3.0 <14.5.0`.
Keep the worker/prewarm API migration so our code is ready for immutable
options. Preserve the other dependency and SDK bounds from ADR 0007.
Use a published dependency constraint, without overrides, cache patches,
Git dependencies, or vendored build_runner sources.

Run `dart run build_runner --help` in both downgrade and upgrade CI jobs
alongside analysis and tests to catch stock fallback compilation failures.

## Consequences

Fresh resolutions and upgrades select at most analyzer 14.4.0, including
downstream consumers of the published package. Projects requiring analyzer
14.5.0 cannot resolve this temporary compatibility window.

Reopen the window after a compatible build_runner release is published and
its private interfaces, package tests, native fixtures, stock builds/watch,
and published-package smoke are validated. An accelerator-only analysis
pass is insufficient to establish stock fallback compatibility.
