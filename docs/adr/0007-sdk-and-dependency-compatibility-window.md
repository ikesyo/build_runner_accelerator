# ADR 0007: SDK and dependency compatibility window

- Status: Accepted
- Date: 2026-09-07

## Context

The project-facing package is intended to be usable by ordinary Dart projects,
not only by the SDK and dependency versions used during development. At the
same time, the Dart worker imports private `build_runner` interfaces for the
resident worker and current build runtime. A broad caret constraint would make
Pub select untested internal API changes without giving the launcher a safe
fallback for compile-time incompatibility.

The current `build_runner` line and its `analyzer`/`build` dependencies require
Dart 3.11 or newer. An attempted resolution with `build_runner 2.15.3` also
showed incompatible private signatures, so the lower bound cannot be reduced
to that release without a separate compatibility implementation.

## Decision

The 0.1.x package line supports Dart `>=3.11.0 <4.0.0` and uses this tested
core dependency window:

- `analyzer >=13.3.0 <15.0.0`
- `build >=4.0.9 <5.0.0`
- `build_config >=1.3.2 <1.4.0`
- `build_runner >=2.16.1 <2.17.0`
- `package_config >=2.2.0 <4.0.0`

The remaining direct dependencies retain caret constraints within their current
major versions. CI validates two resolution points:

- the minimum solution with Dart 3.11.0 and `dart pub downgrade`;
- the current solution with Dart 3.13.3 and `dart pub upgrade`.

Changes to the private `build_runner` surface require a new compatibility
check and an explicit range update. The Rust frontend artifacts remain
platform-specific and are independent of this Dart dependency resolution, but
the launcher, worker, and native protocol continue to share the package
version contract.

## Consequences

Users on Dart versions before 3.11 cannot use the 0.1.x package line. In
exchange, package resolution is broad across the currently compatible
`analyzer`, `build`, `build_config`, and `package_config` releases while
preventing unverified `build_runner` minor releases from entering the worker.
The compatibility matrix becomes a release gate rather than an assumption
based on the maintainer's development SDK.

Supporting an older Dart/build_runner line later should be introduced as a
separately tested compatibility line, not by widening the current constraints
without adapting the private API boundary.

## Alternatives considered

- Keep Dart at `>=3.13.0`: rejected because the current build stack is
  compatible with Dart 3.11 and the higher floor unnecessarily excludes users.
- Use an unbounded `^2.16.1` constraint for `build_runner`: rejected because it
  permits future minor releases that may change the private interfaces.
- Support `build_runner 2.15.x` immediately: rejected because the current
  worker does not compile against its changed private signatures.
