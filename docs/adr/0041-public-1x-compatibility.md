# ADR 0041: Public compatibility for 1.x

- Status: Accepted
- Date: 2026-10-23

## Decision

Use the [launcher reference](../launcher-and-release.md#1x-compatibility-contract)
as the user-facing 1.x contract. Maintain documented public commands, options,
Public environment controls and generation/failure guarantees across 1.x.
Removing supported invocations or narrowing the declared support window needs
a major release. Keep the existing SDK/dependency window from ADR 0007 and the
native-only, output-policy, configuration and recovery boundaries from ADRs
0031–0040; this decision does not add builder support or promise all allowed
dependency combinations have been tested.

Internal IPC and persistence formats remain package implementation details;
compiled workers and caches may regenerate. Preserve pending undo evidence and
refuse unsafe recovery, even when an internal format changes.
Diagnostics and `lib/src` are not extension interfaces. Existing configuration,
probe, distribution and recovery documents own their details rather than a
second specification here.

## Evidence and consequences

Extend the existing minimum/current dependency CI jobs with the same small
Resolver-based stock/native lifecycle comparison. Print SDK, worker mode and
resolved dependencies, retaining ordinary lockfiles and failure logs. This
distinguishes package checks from executing the worker while avoiding another
matrix or a dependency inventory. A passing pair of resolutions establishes
those tested points, not exhaustive SDK/builder/platform coverage. Distribution
E2E and interrupted-publication fault tests remain independent release gates.
