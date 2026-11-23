# API cutoff measurements (2026-11)

Measurements behind the follow-ups to ADR 0056 (API-signature early cutoff). The ADR keeps the decisions and the conclusions; this note keeps the setups, tables and readings they rest on.

## Stage 6 fan-out benchmark (2026-11-22)

The stage 6 fan-out benchmark (`scripts/benchmark_api_cutoff.sh`, generator `scripts/generate_api_cutoff_fanout_fixture.sh`) generates one shared library and 200 consumer libraries that import it, with the stage 5 whole-graph summary builder on every consumer. Measured on the development VM (shared 1.5 CPU, Dart SDK 3.13.3, jobs 2, two runs; outputs byte-identical in every lane). Elapsed times come from the timed pass with metrics disabled, per docs/development.md; action counts come from a separate counted pass. Both passes pin BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 (kernel workers only), so no deferred AOT compilation leaks into a neighboring lane. Each run's timed pass repeats the sequence in both variant orders, so every cell below spans four samples with no fixed run order, and a single timer process brackets each build so interpreter startup stays out of the measurement. An earlier metrics-instrumented measurement overstated every incremental lane for both variants and is superseded by this table.

| Lane | Cutoff off | Cutoff on | Actions off | Actions on |
| --- | --- | --- | --- | --- |
| Clean (fresh cache) | 41.5 to 43.3 s | 40.3 to 42.7 s | 200 | 200 |
| No-op | 0.10 to 0.13 s | 0.10 to 0.13 s | 0 | 0 |
| Body-only edit | 6.7 to 7.3 s | 0.7 to 1.5 s | 200 | 0 |
| Doc-only edit | 6.5 to 7.3 s | 7.0 to 7.3 s | 200 | 200 |
| API edit | 7.2 to 8.7 s | 7.1 to 8.0 s | 200 | 200 |
| Multi-file edit | 6.5 to 7.3 s | 6.7 to 7.9 s | 200 | 200 |

Readings:

- The body-only lane is the design case: the edit stops at the preflight check and no consumer action runs. The residual 0.7 to 1.5 s is snapshot, fingerprint and fold work plus frontend startup.
- The fully cold clean lane shows no measurable cost from enabling the cutoff, fingerprint learning included. This closes the remeasurement deferred from stage 4: cold builds are dominated by manifest generation and worker compilation, not by fingerprinting.
- Doc-only and API edits change the fingerprint by design, so both variants rerun every consumer. The cutoff variant also pays the preflight check, but the end-to-end ranges overlap at this graph size, so the comparison does not resolve a preflight cost; isolating one would need a diagnostic run, which the timed pass deliberately is not.
- The multi-file lane touches every consumer's own input at once, so every action is excluded before any fingerprint query and the cutoff can waive nothing; the lane shows no measurable overhead for broad primary-input edits. It says nothing about broad edits to shared dependencies, which still engage preflight; the doc and API lanes cover the single-dependency case.
- The effective-signature fold stays at planning time (open sub-decision 2). With zero actions running, the whole body-only step completes in 0.7 to 1.5 s end to end at this graph size; the fold's own share is not isolated by this benchmark, but the end-to-end step is small enough that the fold is not on a critical path worth moving to commit time.
- No builder is opted in by default; that remains a separate decision.

## Diagnostics follow-up (2026-11-23)

A field report from a production Flutter app (main at add8cd7 against 0.19.5, interleaved over two rounds) showed the cutoff waiving nothing there: 939 to 940 candidates across riverpod_generator and mockito, 100% disqualified because the observed closure reaches a generated asset (generated `part` files in nearly every library), at a preflight cost of about 1.5 to 2 s of wall time (about 10%) and about 3 s of user CPU. The same report confirmed no regression in any lane (within about 0.5 s) and byte-identical outputs. The disqualification was only visible after ad hoc instrumentation, which is what the cutoff metrics counters (per-builder assess filter reasons and evaluate outcomes under `BUILD_RUNNER_ACCELERATOR_METRICS=1`) now expose directly.

## Generated-part fixture (2026-11-23)

The fan-out fixture generator gained a `GENERATED_PART=1` variant whose shared library has a generated part (a freezed-style partgen builder in the same package), and `scripts/correctness_api_cutoff_generated_part.sh` locks in the behavior on that shape: every candidate is disqualified by the generated-asset rule (visible in the cutoff metrics), all actions rerun on a body-only edit, and outputs stay byte-identical to stock. This is the regression harness for the preflight-skip and generated-asset follow-ups.

## Preflight-skip measurements (2026-11-23)

When the recorded graph alone proves every candidate blocked, assess returns no preflight plan and the worker pool is never started (see the ADR follow-up for the rule and its soundness argument). Measured with debug frontend builds, Dart SDK 3.13.3, `--jobs 2`, on the development VM, interleaved; outputs byte-identical in every comparison. Each app was first built once to record the graph, then timed on the body-only edit build.

- Generated-part fixture (fan-out generator with `GENERATED_PART=1`, 100 consumers, body-only edit of the shared library): 6.6 to 7.9 s with the skip against 6.8 to 8.9 s without. The removed cost is the pool start and query, which grows with the app's analysis context (the field report above measured about 10% of wall time on a production app). The skipped builds' metrics headers show `query_units=0 preflight_skipped=1`, confirming no query was sent.
- Mixed fixture (100 consumers; half repointed at a second, handwritten shared library, both libraries edited): 3.8 s with the skip check against 4.2 s without; the metrics attribution is the same either way (50 signature-unchanged through the handwritten library, 50 blocked through the generated part).
- Source-only fan-out (the plain generator, body edit fully waived): 0.43 s against 0.44 s, so the skip check itself costs nothing measurable on the path that still runs the preflight.

The generated-part correctness harness keeps passing unchanged against the skip, since the skip preserves the metrics attribution it asserts.
