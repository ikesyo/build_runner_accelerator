# ADR 0029: build_runner 2.16.2 and analyzer 14.5 compatibility

- Status: Accepted
- Date: 2026-10-08
- Updates: ADR 0007

## Context

The temporary analyzer upper bound of 14.5.0 protected stock fallback and
fixture builds from build_runner 2.16.1's use of the removed
`AnalysisOptionsImpl.contextFeatures` setter. build_runner 2.16.2 fixes that
resolver using `AnalysisOptionsBuilder`; its published library changes only
that resolver relative to 2.16.1.

## Decision

Restore analyzer to `>=13.3.0 <15.0.0` and require build_runner
`>=2.16.2 <2.17.0`. Keep the minor upper bound because the worker imports
private build_runner interfaces. Update fixture pins and lockfiles to 2.16.2.

## Consequences

The minimum combined dependency solution now uses analyzer 14.3.0 because
build_runner 2.16.2 requires it. Retaining a build_runner 2.16.1 lower bound
would admit the incompatible 2.16.1/analyzer 14.5.0 combination.
build_runner 2.16.0 and older cannot be admitted by constraint changes alone:
the worker's `BuildState` and `BuilderFilesystem` constructor calls require
interfaces introduced in 2.16.1. Supporting those versions requires a separate
adapter and stock/native correctness and watch validation.

Older-version adapters are deferred to avoid adding a companion package and
its release management solely to protect conditional analyzer constraints.
