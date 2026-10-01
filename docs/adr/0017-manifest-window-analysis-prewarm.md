# ADR 0017: Manifest-window analysis prewarm and SDK summary auto-prewarm

- Status: Accepted
- Date: 2026-10-01

## Context

ADR 0011 measured JIT analysis prewarm in two placements and rejected both:
the synchronous compile window was too short to fill a meaningful share of
the byte store, and keeping shards alive through the build contended with
workers. PR71 then made the window before worker spawn much wider: on a
cold build the generator kernel compiles (~10s), the early catalog emits
the worker entrypoint (~1s), the worker AOT compiles (~19s, overlapped),
and the factory probe runs — most of it idle on the Rust side. That
reopened the question of whether the shared analyzer byte store can be
prefilled during the window, bounded so shards die when manifest
generation returns.

## Decision

- `generate_manifest` spawns the same `AnalysisPrewarm` handle used by the
  AOT compile overlap when `BUILD_RUNNER_ACCELERATOR_MANIFEST_PREWARM=1`
  (opt-in, off by default). The handle's `Drop` kills the shards when the
  function returns — after the overlapped AOT compile and factory probe
  finish, before real workers spawn — satisfying the same bound as the
  compile-window spawn.
- A process-local `AtomicBool` makes `spawn_analysis_prewarm`
  single-flight across all windows (`manifest`, `compile`, `aot-prewarm`),
  so an opt-in compile-window spawn inside `prepare_worker_aot` cannot
  double-spawn against a manifest-window owner.
- `bin/prewarm_analysis.dart` accepts `--dirs` (forwarded from
  `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_DIRS`, comma-separated; the
  sentinel `none` exits after summary generation without creating an Analyzer driver) and serializes
  SDK-summary builds through `.dart_tool/build_resolvers/.sdk-summary.lock`
  using an OS exclusive lock with a bounded three-minute wait, so concurrent
  shards on a cold workspace build `sdk.sum` once instead of duplicating
  the multi-second `buildSdkSummary` call.
- Independently of the opt-in flags, `prepare_worker_aot` auto-spawns one
  summary-only shard (`--dirs none`, `sdk-summary` window) when
  `.dart_tool/build_resolvers/sdk.sum` is missing and
  `available_parallelism >= 4`.
  `BUILD_RUNNER_ACCELERATOR_SDK_SUMMARY_PREWARM=0` opts out.

## Measured basis

Cold-build A/B on `fixtures/json_serializable_{10,100,500}_app` (Dart
3.13.4, 8 cores / 31 GB, `BUILD_RUNNER_ACCELERATOR_METRICS=1`, medians of
3, fresh tool/analyzer/byte-store caches per run, outputs byte-identical
to stock):

- Every prewarm variant fills the byte store completely within the window
  (500/500 files resolved, +501 store entries). It never measurably speeds
  up worker resolution: total `resolver_get_us` across 1000 actions is
  ~0.33 s with or without prefill. Workspace-file resolution is simply not
  a cold-build bottleneck on these builders.
- The one real win is the SDK summary. With a cold
  `.dart_tool/build_resolvers/sdk.sum`, every worker's first resolve pays
  ~1.4–2.3 s (`resolver_first_get_us`); one summary-only shard during the
  compile/probe window cuts that to ~0.16 s and saves ~1–3 s of wall time
  (500-file fixture: 31.8 s → 30.1–31.1 s median).
- The manifest-window spawn (top of `generate_manifest`) regresses at the
  default half-core shard count: JIT startup contends with the generator
  kernel compile (+3–4 s on the ~10 s snapshot segment) for no offsetting
  gain — hence opt-in only.
- On a 2-core `taskset` run the same single shard is a ~+9 s regression:
  the kernel compile and `dart compile exe` already saturate both cores,
  so the "idle window" does not exist below 4 cores — hence the
  parallelism gate.

## Consequences

- Cold checkouts on ≥4-core machines save ~1–3 s for free; warm
  workspaces spawn nothing (the `sdk.sum` existence check short-circuits
  before any process is spawned).
- `BUILD_RUNNER_ACCELERATOR_COMPILE_PREWARM=1` with
  `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_JOBS=1` remains the opt-in
  full-prefill configuration; `MANIFEST_PREWARM=1` is available for
  experimentation but not recommended — the kernel-compile segment does
  not pay.
- The prewarm script's `.sdk-summary.lock` also benefits `aot-prewarm`,
  whose shards previously raced to rebuild a missing summary.
- Correctness is unaffected: all changes are additive, diagnostics stay
  on stderr, outputs remain byte-identical to stock, and lock acquisition failures or timeouts
  fall back to the stock summary generator. OS locks are released immediately
  when a shard is killed; the persistent lock file must not be deleted.
