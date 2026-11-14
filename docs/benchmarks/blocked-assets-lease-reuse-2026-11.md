# Batch visibility reuse: local verification and measurement

Measured 2026-11-14 on Linux x64 with a two-CPU quota, 8 GiB memory limit,
Dart 3.13.3 and Cargo 1.98.1. Baseline: main commit `5b2b597` (v0.19.2).
Candidate: the blocked-assets reuse change described in [ADR 0051](../adr/0051-blocked-assets-lease-reuse.md).

## Method

The `single-visibility` scheduler profile has 8,192 inputs and 16,384 generated
outputs, zero artificial delay and two workers. Both native frontends were
release binaries; Dart workers used forced JIT. All variants used one lockfile:
build_runner 2.16.2, Analyzer 14.6.0, build 4.0.11 and build_config 1.3.3.

Stock was an untimed byte reference. Compiler/analysis caches were retained;
clean removed the native graph and generated artifacts. Preparation ran alongside
correctness checks, then paused after warm-up until those checks exited.
Timing excluded that pause and all other verification work. Two repeats used
baseline-first then candidate-first order. Metrics and traces were disabled
during timing; diagnostics ran separately afterward.

Reproduce with separately built baseline/candidate release binaries:

```bash
python3 scripts/benchmark_workspace_scheduler.py \
  --baseline-bin /path/to/baseline --candidate-bin /path/to/candidate \
  --profiles single-visibility --repeat 2 --diagnostics \
  --results /path/to/fresh-results
```

Set `DART_BIN`, `CARGO_BIN` and toolchain/cache overrides as described in
[development](../development.md). The local run used a temporary copy with
a stdin barrier between warm-up and timing; the measured loop was unchanged.

## Recorded artifacts and build identity

The measured candidate is commit `57e52672c659362f9b729ecd89e2ed44e77ff417`,
before the subsequent review fix that invalidates the cache on batch errors.
The original run recorded a dirty checkout based on `5b2b597` in `source_head`;
that field identifies its base, not the candidate revision. The candidate binary
SHA-256 is `a3591773e1e93bd18be6b60541c4ca5ccc639b702e0bfb76d7f9b441f0ce7a45`.
Source and baseline binary hashes are preserved in the original metadata.

- [metadata.json](blocked-assets-lease-reuse-2026-11/metadata.json)
- [samples.json](blocked-assets-lease-reuse-2026-11/samples.json)
- [diagnostics.json](blocked-assets-lease-reuse-2026-11/diagnostics.json)
- [Exact invocation and environment overrides](blocked-assets-lease-reuse-2026-11/invocation.sh)
- [Temporary driver patch](blocked-assets-lease-reuse-2026-11/pause-before-timing.patch)

The three JSON files are unchanged copies from the original run. The harness
sets its own cache, worker mode, metrics and trace settings, as recorded in
metadata and the per-sample commands. CPU model was not captured at measurement
time; a later query in the retained environment reported
`INTEL(R) XEON(R) PLATINUM 8573C`. This later observation is not an original run
measurement. The original CPU quota remains recorded in metadata.

## Wall time

Seconds, both samples followed by their median. Every sample and warm-up
matched all 16,384 stock-generated files byte for byte.

| Lane | Baseline | Reuse |
| --- | ---: | ---: |
| clean | 39.245 / 32.448 (**35.846**) | 25.233 / 29.427 (**27.330**) |
| noop | 0.777 / 0.565 (**0.671**) | 0.515 / 0.666 (**0.591**) |
| one-file | 2.180 / 2.073 (**2.127**) | 1.942 / 2.427 (**2.184**) |
| broad | 36.061 / 32.552 (**34.306**) | 25.403 / 28.021 (**26.712**) |

Clean and broad-edit medians improved by approximately 24% and 22%.
No-op and one-file results are too close and variable to establish a change.
A leaf edit executes only a small number of actions, so it offers little
opportunity to reuse a large hint across leases.

## IPC diagnostics

A separate broad edit enabled metrics, wall trace and fixture action history.
Both variants executed 16,384 actions on two real worker processes and remained
byte-identical to stock. These instrumented runs are excluded from the wall-time
table above.

| Metric | Baseline | Reuse |
| --- | ---: | ---: |
| `ipc_bytes_sent` | 145,620,273 | 12,567,613 |
| `ipc_frames_sent` | 33,098 | 33,078 |
| `build_result_frames` | 326 | 306 |
| cumulative `build_us` (seconds) | 112.738 | 70.332 |

Sent IPC bytes fell by **91.4%**, from 145.6 MB to 12.6 MB.
Batch counts differ slightly because adaptive scheduling observes action time;
mean total sent bytes per batch response fell from 446,688
to 41,071. This includes asset RPC traffic and is not
the isolated size of the hint. Scheduling policy was unchanged.

## Correctness and checks

- `cargo test --locked --manifest-path rust/Cargo.toml`: 262 passed, 3 ignored.
- `cargo clippy --locked --manifest-path rust/Cargo.toml --all-targets --all-features -- -D warnings`: passed.
- Dart analysis and Dart/Rust formatting checks passed.
- `dart test --timeout 3m`: 396 passed in the full run; six environment-dependent
  cases passed on targeted rerun, completing all 402. Five download tests needed
  loopback sockets outside the sandbox; the phase-reset helper was precompiled,
  as in CI, to avoid its fixed 30-second source-startup deadline.
- `VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh`: smoke, manifest snapshots,
  AOT/JIT catalog checks, upgrade, trigger/optional and arbitrary-builder cases
  passed. The aggregate command stopped at the final package-target fixture's
  online Pub advisory lookup in the sandbox. Retrying
  `bash scripts/correctness_arbitrary_package_target_builder.sh` with network
  access passed auto-apply, target boundaries and phase order.
- `bash scripts/correctness_workspace_scheduler.sh`: passed workspace and
  single-package lifecycle, jobs limits, phase/context isolation, failure,
  worker-exit recovery and same-phase resolver-baseline reuse comparisons.
- `python3 scripts/test_benchmark_workspace_scheduler.py`: passed.

## Review follow-up

The later review fix clears the native reuse cache on every ordinary or lazy
batch error. Regression coverage verifies full-list retransmission after worker
rejection, malformed results and interruption, while successful batches retain
reuse. The rejection/retry assertion failed before the fix and passed afterward.
The updated Rust suite passed 263 tests (3 ignored), with Clippy and formatting
checks passing. The timing and IPC tables still describe the original measured
candidate identified above; performance was not remeasured after this error-path
change.

## Limits

Two repeats on one Linux host are a local regression check, not a statistical
claim for other projects. No OS-cold or worker-AOT-cold timings were taken.
The full `VERIFY_LEVEL=full` integration matrix and separate watch, Freezed
and Riverpod suites were not run for this change. The supplied private-project
reports in ADR 0051 are independent evidence, not timings of this patch.
