# Workspace and single-package scheduler benchmarks

Measure the 100ms/16-input policy at `d204a4e1463b92e9bcb86e431460cf87b22a9ecd`
against the preceding 20ms/8-input policy at
`0aac2a75b5b9f8e5a1b79777f55e5b1e26c9badd`. Both already use dynamic input
leasing. Also compare the ordinary executor's earlier static partitions at
`b0e659a1bd75d30aec4bdd6a80b75bbcfc34dfa0` directly with the candidate.
These are two independent paired experiments; do not combine their ratios or
compare cells across experiments as a third paired comparison.

The candidate also bypasses dispatch threads/channels when the effective worker
count is one. It includes the explicit lock-release correction at `43e9f73`;
the two earlier retained binaries precede that correction. Dart worker sources
are identical across the variants used in each comparison.

## Findings

The larger bounded batches reduce batch responses and transmitted bytes in both
worker modes. This does **not** establish a consistent end-to-end improvement.
AOT workspace clean/broad medians decrease about 3%, with overlapping ranges.
AOT uniform standalone clean is 0.366s → 0.316s and broad is 0.317s → 0.315s,
also with overlapping ranges. JIT uniform standalone clean/broad medians are
11.1%/3.1% slower than the preceding adaptive policy in this run.

Relative to static partitions, artificial uneven inputs retain a clear benefit:
AOT clean/broad medians decrease 32.4%/31.9%;
JIT decreases 30.1%/26.6%. These n=3 skew ranges do not overlap. Uniform cases
remain mixed. This is evidence for synthetic load balancing, not a general
real-project speedup or an absence of scheduling overhead.

## Conditions and reproduction

Measured on 2026-10-28–29, Linux x86_64, cgroup quota `200000 100000` (2 CPUs),
Dart 3.13.3, Rust/Cargo 1.98.1 and Python 3.12.14. Both frontends use release binaries, `--jobs 3`,
identical dependency solutions and the same pub/native cache within a comparison.
The shared analysis byte store is enabled. Ordinary execution retains its existing
resolver cap: three resident processes, two processes running builders; the
workspace profile uses three builder processes. Resident workers remain within
`--jobs` in both modes.

| Profile | Scope | Inputs | Artificial native async waits |
| --- | --- | --- | --- |
| many | Workspace, A inputs only | 120 | None |
| single-balanced | Standalone A | 120 | None |
| single-inputs | Standalone A | 12 | First three seeds 2000ms; other seeds and summaries 200ms |

Stock build_runner 2.16.2/analyzer 14.6.0 is an **untimed byte reference**. Its
fixture waits are explicitly zero; waits do not contribute to output bytes.
Both timed native variants receive the same profile-specific waits. All **336**
completed native timed samples matched stock source/cache bytes, as did the
separate diagnostics. Generated JSON, histories and executable metadata remain
outside Git.

Preparation warms both native variants. Clean removes graph/generated outputs
while retaining compiled worker artifacts and analysis caches; this is cache-warm
clean, not cold startup. Variant order alternates by repetition. No other local
builds or tests ran during timing. Metrics, histories and wall tracing are off
for timed runs, and enabled only in separate diagnostic builds.

AOT uses strict `--force-aot`, not automatic/background artifact selection. Warm
builds finish compilation before timing. Metadata records executable SHA-256 and
mtime; every timed AOT sample checks that its prepared executable was not rebuilt.
Separate Linux `/proc/<builder-pid>/exe` observations confirmed the warmed AOT
executable for every builder PID in the completed diagnostic runs. JIT diagnostic
observations identify `dartvm`. AOT here describes builder workers: workspace
Dart discovery helpers still contribute to command startup.

The workspace AOT n=5 set consists of two prepared blocks (3+2 complete
repetitions) after a process interruption. The native cache was retained and both
variants warmed for the second block; repetition/source-value labels restart in
that block. Four samples from the unfinished repetition remain in the original
raw artifacts and are excluded by the complete-repetition rule. Other profile
sets completed without this interruption. Segment metadata preserves original
commands, source/binary fingerprints and artifact identities.

Retain each release frontend separately. With the SDK/cache overrides documented
in the [development guide](../../development.md), run from the candidate checkout:

```bash
for mode in jit aot; do
  python3 scripts/benchmark_workspace_scheduler.py \
    --baseline-bin /path/to/20ms-binary --candidate-bin /path/to/100ms-binary \
    --worker-mode "$mode" --profiles many,single-balanced,single-inputs \
    --repeat 5 --diagnostics --results "/path/to/new-adaptive-$mode-results"
  python3 scripts/benchmark_workspace_scheduler.py \
    --baseline-bin /path/to/static-binary --candidate-bin /path/to/100ms-binary \
    --worker-mode "$mode" --profiles single-balanced,single-inputs \
    --repeat 3 --diagnostics --results "/path/to/new-static-$mode-results"
done
```

The harness is at `fb94a70d1b2af9184645b9d1442dec4348d4bed5` for AOT and
static comparisons; the initial JIT adaptive comparison uses `64b3340` before
adding explicit mode selection/process observation. Timed JIT commands are
unchanged. Native binary SHA-256:

- 20ms/8: `72ad3dcb4ae72437176ffeef6975fcc13b24c0561ea9851326124afdee5e529b`
- 100ms/16: `8806a862438aeb5ee236eef3032c238b538935ba6bef3f0edc24fd617666061c`
- Static: `b5c3189bbfad9d0fc67825dd9fff6bc7c74f29e48bf10c5dc95117dd704dea83`

## Preceding adaptive policy versus candidate

Seconds: median (minimum–maximum), n=5 per cell. Negative change means shorter
elapsed time. No-op controls and sub-0.5s cells omit percentage changes: no-op
runs do not enter the input scheduler, and Python's timeout-based child wait
has coarse granularity for very short commands. One-file runs have two serial
actions and already use one worker; their differences are not attributed to
input load balancing or the new retained-pool fast path.

| Mode | Profile | Case | Baseline seconds | Candidate seconds | Change |
| --- | --- | --- | --- | --- | --- |
| AOT | many | clean | 3.865 (3.592–4.100) | 3.756 (3.342–4.346) | -2.8% |
| AOT | many | noop | 3.618 (3.356–4.040) | 3.105 (3.100–4.415) | — |
| AOT | many | one-file | 3.613 (3.533–4.020) | 3.735 (3.248–4.311) | +3.4% |
| AOT | many | broad | 3.704 (3.464–4.069) | 3.591 (3.287–3.982) | -3.1% |
| AOT | single-balanced | clean | 0.366 (0.265–0.369) | 0.316 (0.265–0.473) | — |
| AOT | single-balanced | noop | 0.018 (0.016–0.033) | 0.032 (0.016–0.032) | — |
| AOT | single-balanced | one-file | 0.165 (0.164–0.372) | 0.165 (0.164–0.215) | — |
| AOT | single-balanced | broad | 0.317 (0.315–0.423) | 0.315 (0.265–0.365) | — |
| AOT | single-inputs | clean | 5.522 (5.510–5.624) | 5.551 (5.495–5.612) | +0.5% |
| AOT | single-inputs | noop | 0.008 (0.008–0.016) | 0.008 (0.008–0.016) | — |
| AOT | single-inputs | one-file | 2.479 (2.426–2.483) | 2.481 (2.427–2.541) | +0.1% |
| AOT | single-inputs | broad | 5.557 (5.490–5.756) | 5.560 (5.495–5.769) | +0.1% |
| JIT | many | clean | 7.345 (6.747–7.426) | 6.922 (6.292–7.780) | -5.8% |
| JIT | many | noop | 3.346 (3.250–3.759) | 3.259 (3.059–3.640) | — |
| JIT | many | one-file | 4.297 (4.009–4.671) | 4.494 (4.411–5.232) | +4.6% |
| JIT | many | broad | 7.013 (6.621–7.335) | 6.784 (6.185–7.137) | -3.3% |
| JIT | single-balanced | clean | 2.403 (2.293–2.988) | 2.671 (2.487–2.821) | +11.1% |
| JIT | single-balanced | noop | 0.032 (0.016–0.033) | 0.016 (0.016–0.032) | — |
| JIT | single-balanced | one-file | 0.918 (0.766–0.994) | 1.051 (0.821–1.283) | +14.4% |
| JIT | single-balanced | broad | 2.468 (2.438–3.069) | 2.545 (2.446–2.974) | +3.1% |
| JIT | single-inputs | clean | 7.005 (6.803–7.234) | 6.902 (6.822–7.005) | -1.5% |
| JIT | single-inputs | noop | 0.016 (0.008–0.016) | 0.008 (0.008–0.016) | — |
| JIT | single-inputs | one-file | 3.397 (3.183–3.445) | 3.260 (3.087–3.454) | -4.0% |
| JIT | single-inputs | broad | 7.124 (6.961–7.286) | 7.092 (6.914–7.309) | -0.5% |

## Static partitions versus candidate

Seconds: median (minimum–maximum), n=3 per cell. The static baseline already
amortizes IPC into large contiguous partitions. Dynamic dispatch can send more
batches while reducing waiting for uneven inputs.

| Mode | Profile | Case | Baseline seconds | Candidate seconds | Change |
| --- | --- | --- | --- | --- | --- |
| AOT | single-balanced | clean | 0.318 (0.315–0.326) | 0.316 (0.269–0.365) | — |
| AOT | single-balanced | noop | 0.016 (0.016–0.016) | 0.016 (0.016–0.016) | — |
| AOT | single-balanced | one-file | 0.165 (0.164–0.165) | 0.165 (0.164–0.319) | — |
| AOT | single-balanced | broad | 0.315 (0.315–0.474) | 0.320 (0.315–0.470) | — |
| AOT | single-inputs | clean | 8.214 (8.169–8.219) | 5.557 (5.511–5.595) | -32.4% |
| AOT | single-inputs | noop | 0.008 (0.008–0.016) | 0.016 (0.008–0.016) | — |
| AOT | single-inputs | one-file | 2.485 (2.428–2.588) | 2.425 (2.373–2.480) | -2.4% |
| AOT | single-inputs | broad | 8.238 (8.163–8.242) | 5.608 (5.550–5.895) | -31.9% |
| JIT | single-balanced | clean | 2.543 (2.536–2.627) | 2.494 (2.127–2.965) | -2.0% |
| JIT | single-balanced | noop | 0.016 (0.016–0.016) | 0.016 (0.016–0.032) | — |
| JIT | single-balanced | one-file | 0.871 (0.769–0.917) | 0.770 (0.716–0.924) | -11.6% |
| JIT | single-balanced | broad | 2.597 (2.243–2.944) | 2.590 (2.439–2.880) | -0.3% |
| JIT | single-inputs | clean | 9.851 (9.683–9.852) | 6.885 (6.812–6.896) | -30.1% |
| JIT | single-inputs | noop | 0.016 (0.008–0.016) | 0.008 (0.008–0.016) | — |
| JIT | single-inputs | one-file | 3.288 (3.128–3.345) | 3.438 (3.188–3.748) | +4.6% |
| JIT | single-inputs | broad | 9.569 (9.552–10.061) | 7.019 (6.811–7.149) | -26.6% |

## Separate IPC diagnostics

Untimed broad edits, with metrics/history/wall tracing enabled. Counts can
influence the timing-based batch policy and are not claimed to be the exact
counts of timed samples. Pool size and process count alone do not prove overlap;
CI's rendezvous/start–end interval checks provide concurrency evidence.

| Mode | Comparison | Profile | Batch responses | Sent frames | Sent bytes | Resident/builder processes |
| --- | --- | --- | --- | --- | --- | --- |
| AOT | Adaptive | many | 70 → 61 | 556 → 547 | 618791 → 559781 | 3/3 |
| AOT | Adaptive | single-balanced | 56 → 45 | 542 → 531 | 528585 → 461264 | 3/2 |
| AOT | Adaptive | single-inputs | 24 → 24 | 78 → 78 | 47563 → 47581 | 3/2 |
| AOT | Static | single-balanced | 4 → 45 | 490 → 531 | 208147 → 461265 | 3/2 |
| AOT | Static | single-inputs | 4 → 24 | 58 → 78 | 33803 → 47581 | 3/2 |
| JIT | Adaptive | many | 178 → 80 | 664 → 566 | 1184351 → 676530 | 3/3 |
| JIT | Adaptive | single-balanced | 96 → 54 | 582 → 540 | 746855 → 515698 | 3/2 |
| JIT | Adaptive | single-inputs | 24 → 24 | 78 → 78 | 47509 → 47527 | 3/2 |
| JIT | Static | single-balanced | 4 → 54 | 490 → 540 | 207643 → 515567 | 3/2 |
| JIT | Static | single-inputs | 4 → 24 | 58 → 78 | 33731 → 47509 | 3/2 |

Resolver resets remain three in each of these diagnostic builds. Input timing
estimates stay within an application; context reassignment, phase visibility,
dependency release and transactional publication follow [ADR 0046](../../adr/0046-workspace-action-scheduler.md).

AOT workspace baseline: separately instrumented command 3.653s, recorded native
build 0.381s. Candidate: command 3.470s, recorded native build 0.334s.
Time outside that span includes the two official Dart discovery-helper
invocations and other setup/teardown; it is not an exact discovery-only
measurement. This startup cost remains after input dispatch is optimized.

Global phase barriers and conservative ordering remain. An unexpectedly expensive
input inside a learned batch can still cause a straggler. Larger real workspaces
and mixed builders require separate measurements; these results do not justify
a general JIT/AOT speedup claim or a change to the resident-worker `--jobs` budget.


## Earlier measurements

Earlier JIT experiments measured the wave-to-ready transition and the initial
20ms/8-input adaptive policy. Their full conditions, output comparisons and
results remain in the pinned historical versions:

- [Wave versus dependency-ready scheduling](https://github.com/ikesyo/build_runner_accelerator/blob/07e567eaeecc98a830abd8be73bd9d01b9820f10/docs/benchmarks/workspace-scheduler-2026-10/README.md).
- [Initial adaptive batching and visible-baseline reuse](https://github.com/ikesyo/build_runner_accelerator/blob/07e567eaeecc98a830abd8be73bd9d01b9820f10/docs/benchmarks/workspace-scheduler-2026-10/adaptive.md).

These are separate experiments on earlier implementations. Use the JIT/AOT
comparisons above to assess the measured 100ms/16-input policy; do not combine
results across experiments into a speedup estimate.
