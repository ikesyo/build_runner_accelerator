# ADR 0007: SDK and dependency compatibility window

- Status: Accepted
- Date: 2026-09-07

## Context

The package must work across supported application dependency solutions, while
its Dart worker imports private build_runner and Analyzer interfaces. Pub
resolution and launcher compilation alone cannot establish compatibility with
those interfaces. An unbounded runner range could select an unvalidated private
API change.

## Decision

Maintain an explicitly validated dependency window in the
[compatibility contract](../launcher-and-release.md#supported-dependencies).
That guide owns the current SDK/package ranges and version-specific limits;
this ADR defines the policy for changing them.

Validate both minimum and current resolutions with `pub downgrade` and
`pub upgrade`, including compilation and execution of the generated worker.
Changes to private runner interfaces require a compatibility check and an
explicit range update. Older runners can share the release line when a bounded
adapter preserves the same behavior; [ADR 0042](0042-runner-resolver-compatibility.md)
defines the resolver backport and runtime adapter.
[ADR 0043](0043-shared-library-parts.md) defines shared-library execution.

Native artifacts remain platform-specific and independent of Dart dependency
resolution. The launcher, worker and native protocol retain the package version
contract; supported resolutions use one package and release pipeline.

## Consequences

Compatibility is a release gate rather than an assumption based on the
maintainer's SDK. A wider Pub range does not override a generator's own
constraints or establish support for every dependency combination.
The [development guide](../development.md#sdk-lifecycle-comparison) owns
verification commands and comparison limits.

## Alternatives considered

- Support only the development SDK: unnecessarily excludes compatible projects.
- Accept future runner minor releases through a broad caret constraint: private
  interfaces can change before the worker has been adapted and validated.
- Publish separate packages for older runners: unnecessary while a bounded,
  tested adapter can preserve the same execution and publication guarantees.
