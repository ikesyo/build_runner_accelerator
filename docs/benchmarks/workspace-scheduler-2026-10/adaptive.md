# Adaptive input dispatch and visible-baseline reuse

This historical comparison measures the 20ms/8-input policy. See the subsequent
[JIT and AOT measurements](overhead.md) for the current 100ms/16-input policy,
its IPC reductions and mixed end-to-end results.

Compare the preceding ready-queue implementation at
`b0e659a1bd75d30aec4bdd6a80b75bbcfc34dfa0` against adaptive batching,
indexed readiness and phase-visible baseline reuse at
`0aac2a75b5b9f8e5a1b79777f55e5b1e26c9badd`.
The harness is committed at `d200a500569bfa38316d6111d3e14844dd7328d1`.
The baseline already schedules independent workspace actions dynamically, one
input per lease; its ordinary single-package executor uses fixed contiguous
partitions. The candidate shares adaptive input leasing across both executors.

## Conditions and reproduction

Linux x86_64, 2-CPU cgroup quota; Dart 3.13.3, Cargo/Rust 1.98.1.
Both native binaries use the release profile, JIT workers, the shared byte store,
identical toolchains, lockfiles and pub/native caches. Stock build_runner 2.16.2
with analyzer 14.6.0 is an **untimed output reference**, not a timing baseline.

Untimed preparation warms both native variants. Clean removes graph/generated
artifacts while retaining compiler and analysis caches: cache-warm clean, not
cold startup. Three repetitions alternate variant order. No other local builds
or tests ran during timing. Metrics and histories are disabled for timed runs;
separate diagnostics run after each profile's timing.

Build both revisions with `cargo build --release --manifest-path rust/Cargo.toml`
and retain the binaries separately. With matching SDK/cache environment, run:

```bash
export DART_BIN=/path/to/dart-sdk/bin/dart
export CARGO_BIN=/path/to/cargo
export CARGO_HOME=/path/to/cargo-home
export RUSTUP_HOME=/path/to/rustup-home
export PUB_CACHE=/path/to/pub-cache
python3 scripts/benchmark_workspace_scheduler.py \
  --baseline-bin /path/to/ready-queue-binary \
  --candidate-bin /path/to/adaptive-binary \
  --results /path/to/new-results-directory --repeat 3 \
  --profiles skew,balanced,many,inputs,single-balanced,single-inputs \
  --diagnostics
```

The script records metadata, every timed command/duration, inventory digests,
lockfiles and diagnostic histories in the results directory. Generated JSON is
not tracked. Measured binary SHA-256 digests:

- Baseline: `b5c3189bbfad9d0fc67825dd9fff6bc7c74f29e48bf10c5dc95117dd704dea83`
- Candidate: `72ad3dcb4ae72437176ffeef6975fcc13b24c0561ea9851326124afdee5e529b`

Profiles use the same tracked builder. Workspace A/B are independent and C
requires A; single profiles convert a fresh copy into a standalone package.

| Profile | Inputs | jobs | Artificial async delays |
| --- | --- | --- | --- |
| skew | A/B/C: one each | 2 | A=200ms, B=2000ms, C=1800ms |
| balanced | A: 12 | 3 | None |
| many | A: 120 | 3 | None |
| inputs | A: 12 | 3 | First three seeds=2000ms; others and summaries=200ms |
| single-balanced | Standalone A: 120 | 3 | None |
| single-inputs | Standalone A: 12 | 3 | Same skew as inputs |

Both ordinary executors retain the pre-existing resolver-worker cap: these
jobs=3 single-package runs use two builder processes while up to three resident
workers remain within the declared limit. Async delays model uneven durations,
not CPU-bound Dart computation.

## End-to-end results

All **144** timed native samples were byte-identical to stock for declared source
and cache outputs. Seconds: median (minimum–maximum), n=3. Change is candidate
relative to baseline; negative means less elapsed time.

| Profile | Case | Baseline | Candidate | Change |
| --- | --- | --- | --- | --- |
| skew | clean | 9.818 (9.744–11.052) | 10.099 (9.302–11.314) | +2.9% |
| skew | noop | 4.399 (3.692–4.400) | 4.076 (3.600–5.152) | -7.3% |
| skew | one-file | 8.173 (7.159–8.443) | 8.628 (7.402–11.793) | +5.6% |
| skew | broad | 11.558 (9.723–12.582) | 9.863 (9.536–11.372) | -14.7% |
| balanced | clean | 6.548 (6.221–8.769) | 6.900 (6.251–7.693) | +5.4% |
| balanced | noop | 4.062 (3.962–4.077) | 3.819 (3.597–4.178) | -6.0% |
| balanced | one-file | 4.351 (4.305–5.216) | 5.249 (4.699–6.016) | +20.6% |
| balanced | broad | 6.415 (5.843–6.694) | 6.183 (6.140–6.298) | -3.6% |
| many | clean | 8.235 (7.580–8.601) | 7.471 (7.224–8.888) | -9.3% |
| many | noop | 3.915 (3.647–4.139) | 3.794 (3.621–3.917) | -3.1% |
| many | one-file | 5.137 (4.312–5.385) | 4.552 (4.314–4.807) | -11.4% |
| many | broad | 8.419 (7.640–8.927) | 8.753 (7.927–9.884) | +4.0% |
| inputs | clean | 10.309 (10.250–11.341) | 9.978 (9.197–10.644) | -3.2% |
| inputs | noop | 3.962 (3.728–4.254) | 3.908 (3.653–4.386) | -1.4% |
| inputs | one-file | 7.610 (7.357–7.713) | 7.626 (7.404–7.647) | +0.2% |
| inputs | broad | 9.492 (9.394–10.229) | 10.090 (9.203–10.926) | +6.3% |
| single-balanced | clean | 3.623 (3.269–4.561) | 3.811 (2.639–4.301) | +5.2% |
| single-balanced | noop | 0.033 (0.016–0.038) | 0.032 (0.016–0.032) | -2.0% |
| single-balanced | one-file | 0.976 (0.867–1.323) | 1.228 (1.129–1.248) | +25.9% |
| single-balanced | broad | 3.081 (2.936–3.534) | 2.740 (2.675–3.348) | -11.1% |
| single-inputs | clean | 9.944 (9.802–10.645) | 7.705 (7.272–7.728) | -22.5% |
| single-inputs | noop | 0.016 (0.008–0.018) | 0.016 (0.008–0.018) | -2.6% |
| single-inputs | one-file | 3.284 (3.281–3.517) | 3.329 (3.294–3.555) | +1.4% |
| single-inputs | broad | 10.003 (9.975–10.005) | 7.236 (7.150–7.240) | -27.7% |

The standalone skewed-input clean median falls from 9.944s to 7.705s (22.5%)
and broad editing from 10.003s to 7.236s (27.7%). These ranges do not overlap in
this three-sample experiment. This establishes a benefit for the artificial
uneven-input case, not a real-project speedup. Ordinary uniform-input broad
editing has an 11.1% shorter median with overlapping ranges; its clean and
one-file medians are slower. Workspace results are also mixed, including a
4.0% slower broad-edit median for 120 cheap inputs.

Keep the ranges alongside the medians; three repetitions do
not establish statistical significance or a general real-project speedup.
No-op does not execute the input scheduler, and one-file runs here have only two
serial actions, so their differences are not attributed to dynamic input
balancing. Light and uniform inputs can pay more dispatch/IPC overhead than
static partitions. Unexpected expensive inputs inside a learned batch can still
leave a straggler. Larger mixed-builder workloads remain unvalidated.

## Separate worker and IPC diagnostics

Each row compares untimed broad edits with metrics/history enabled. All outputs
also matched stock. Resident count is the pool metric; builder process count is
from actual builder start records. Concurrency correctness is additionally
verified by rendezvous and overlapping start/end intervals in the fixture tests.

| Profile | Actions | Batch responses | Resolver resets | Resident/builder processes |
| --- | --- | --- | --- | --- |
| skew | 6 | 6 → 6 | 6 → 3 | 2/2 → 2/2 |
| balanced | 24 | 24 → 24 | 6 → 3 | 3/3 → 3/3 |
| many | 240 | 240 → 189 | 6 → 3 | 3/3 → 3/3 |
| inputs | 24 | 24 → 24 | 6 → 3 | 3/3 → 3/3 |
| single-balanced | 240 | 4 → 116 | 3 → 3 | 3/2 → 3/2 |
| single-inputs | 24 | 4 → 24 | 3 → 3 | 3/2 → 3/2 |

Timing-based adaptive choices can differ under instrumentation; these counters
are not claimed to be the exact batch counts of the timed runs. Workspace
baseline batching starts from one-input leases, whereas the ordinary baseline
already amortizes IPC in large static partitions. Dynamic ordinary dispatch can
therefore increase batch count while reducing waiting for uneven inputs.
Baseline reuse reduces redundant hydration without storing extra parked
processes or changing the resident-worker `--jobs` bound.

See [ADR 0046](../../adr/0046-workspace-action-scheduler.md) for visibility,
state isolation, phase barriers and the all-success publication boundary.
