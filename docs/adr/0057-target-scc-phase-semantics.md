# ADR-0057: target SCC phase semantics in the generic manifest

- Status: accepted
- Date: 2026-09-05

## Context

ADR-0056 added dependency-owned targets but linearized every target. That is
not enough for a target graph containing a cycle. build_runner computes
strongly connected components and expands each component in dependency-first
order. For each component it applies the globally ordered BuilderApplication
list first, then creates one target-specific phase for each applicable target
member. A target member must not see a stale output from a phase that is being
rebuilt, while a later member can observe a fresh output from an earlier
member.

The generic Rust planner also decided dirty actions only from the filesystem
snapshot at build start. A downstream action which read an output of an
upstream dirty action was therefore missed until a later build.

## Decision

- Manifest version 4 replaces the previous target linearization. The Dart
  manifest generator computes target SCCs with the same stable graph-node
  order and dependency traversal as build_runner's
  `stronglyConnectedComponents`. `target_order` identifies the SCC, and
  `phase` encodes the global builder order followed by the target member order
  within that SCC.
- Rust sorts configured entries by `(target_order, phase, target, builder)`.
  The existing generic phase loop therefore executes the same builder/target
  order without adding a builder-name branch or a separate cycle scheduler.
- Before worker execution, Rust expands the dirty set through recorded
  `reads` and `resolver_reads` from dirty action outputs. This is a generic
  output-to-reader closure and applies to acyclic and cyclic target graphs.
- Outputs recorded by dirty actions are added to the worker's deleted overlay
  until their new result is published. A fresh result removes that asset from
  the deleted overlay and is visible to later phases through the existing
  overlay reader. Delete-only builds do not start a worker.
- The compatibility boundary remains the same for builder features: the
  cycle path supports the existing non-optional, representable definitions;
  optional demand-driven phases, non-root source outputs, post-process
  builders, and other unsupported mappings still use fallback/error handling.

## Consequences

- Same-builder actions in a target SCC can preserve build_runner's member
  ordering and phase visibility with the generic manifest and worker path.
- The dirty closure may conservatively rerun a reader when its producer is
  dirty, which preserves correctness before output bytes are known. The
  recorded output digests still suppress work on a subsequent no-op.
- Manifest and graph compatibility are invalidated by the v4 manifest
  transition, so a v3 linearized manifest cannot be reused accidentally.
- A worker still changes package context at a package boundary. Cross-package
  SCCs use the same generic restart boundary and remain limited to the
  package-aware cache-output subset.

## Verification

`scripts/correctness_target_cycle.sh` compares stock and Rust for a two-node
same-package target SCC. The fixture checks clean output, no-op, upstream
change propagation, same-phase stale-output hiding, and delete-only cleanup.
Rust 1.98.1 unit tests and the existing arbitrary-builder, dependency-target,
capture, and watch regressions remain green.
