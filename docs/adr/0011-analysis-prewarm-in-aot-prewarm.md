# ADR 0011: Analysis prewarm in `aot-prewarm`

- Status: Accepted
- Date: 2026-09-26

## Context

A cold build pays two serial costs before worker execution can run at full
speed: the synchronous worker AOT compile, and the first-touch analyzer work
that fills the shared on-disk byte store (ADR 0009). Measured on the
reference workspace, an unprimed cold build runs ~37s of execution versus
~24s once the byte store is warm; the AOT compile itself is ~17s.

Two placements for warming the byte store during the build were measured and
rejected:

- JIT prewarm only during the synchronous compile window produced ~0 net
  gain: driver and SDK-summary startup consume much of the window, and only
  a small fraction of sources were warmed before the compile ended.
- Keeping the prewarm processes alive through the build was a measurable
  regression: on an 8-core machine the extra JIT work contends with the
  worker processes the whole build.

The `aot-prewarm` command already exists as the cold-priming step for the
worker executable (e.g. CI image/cache warming). Priming the analysis byte
store belongs to the same step: the byte store lives under the machine-wide cache root and the AOT
store publishes into it (ADR 0012), and both are keyed by toolchain- and
workspace-derived fingerprints, so they can be warmed in one pass and then
shared by every subsequent build until the toolchain or dependencies change.

## Decision

- `aot-prewarm` additionally spawns `bin/prewarm_analysis.dart` processes —
  plain JIT `AnalysisDriver`s — sharded across
  `available_parallelism / 2` workers, that resolve the workspace package's
  `lib/`, `test/`, and `integration_test/` sources into the shared
  content-addressed byte store while the AOT compile runs and until they
  finish enumerating.
- The prewarm driver constructs the same byte store as the worker
  (`sharedAnalysisByteStore` in `lib/src/worker_resolvers.dart`), including
  the same SDK summary bytes and package-config inputs, so key identity and
  fingerprint partitioning match exactly. Misses are impossible to
  distinguish from a cold entry; at worst workers recompute what the
  prewarmer did not reach.
- The prewarm is strictly additive and outside the build path: `build`
  never spawns it. `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM=0` disables
  it; `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_JOBS` overrides the shard
  count; `BUILD_RUNNER_ACCELERATOR_BYTE_STORE=0` disables it along with the
  shared store itself.
- Correctness is unaffected: the byte store is read-through with
  content-addressed keys, prewarm uses identical key derivation, and
  generated outputs must remain byte-identical to stock `build_runner`
  regardless of store temperature.

## Consequences

- A primed cold build (byte store + AOT caches warm, graph/cache cleared)
  measures ~24s versus ~37s unprimed on the reference workspace — faster
  than stock `build_runner`'s warm build.
- CI/dev-image flows that already run `aot-prewarm` now prime both caches in
  one step; nothing else changes.
- `bin/prewarm_analysis.dart` is a build-runner tool that reaches into
  `package:analyzer` and `package:build_runner` implementation libraries
  (`implementation_imports`). It must track the supported analyzer window
  (ADR 0007); a failing or missing prewarm script degrades to a normal cold
  build rather than breaking it.
