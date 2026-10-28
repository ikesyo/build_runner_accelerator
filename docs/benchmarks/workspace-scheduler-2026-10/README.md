# Workspace scheduler comparison, 2026-10-28

Compare the bounded wave scheduler at `f19ad209a0a8b18188c3fae24524326d494d99c2`
with dependency-ready scheduling and single-input leases at
`b0e659a1bd75d30aec4bdd6a80b75bbcfc34dfa0`.
Both are native implementations; stock build_runner is an untimed output reference.

## Conditions and reproduction

Linux x86_64, cgroup CPU quota 2 CPUs; Dart 3.13.3, Rust/Cargo 1.98.1.
Both native binaries use the release profile and identical toolchains, lockfiles,
pub cache and shared native compilation cache. Workers run in JIT mode with the
shared byte store enabled. Metrics and diagnostic histories are disabled during
timing. Each profile receives untimed preparation for both variants, then three
repetitions with alternating variant order. Clean removes native graph and
generated outputs while retaining compiler and analysis caches: these are
cache-warm clean builds, not cold startup measurements.

Build each revision using `cargo build --release --manifest-path rust/Cargo.toml`
and retain its `build_runner_accelerator` binary separately. From the candidate
checkout, with the same SDK/cache environment for both binaries, run:

```bash
export DART_BIN=/path/to/dart-sdk/bin/dart
export CARGO_BIN=/path/to/cargo
export CARGO_HOME=/path/to/cargo-home
export RUSTUP_HOME=/path/to/rustup-home
export PUB_CACHE=/path/to/pub-cache
python3 scripts/benchmark_workspace_scheduler.py \
  --wave-bin /path/to/wave-binary --ready-bin /path/to/ready-binary \
  --results /path/to/new-results-directory --repeat 3
```

`metadata.json` records the measured toolchains, binary/source digests and exact
profiles. `samples.json` retains every timed command, duration and output inventory
digest. `summary.json` contains medians and ranges. All **72** native timed samples
were byte-identical to the stock reference, including source and cache outputs.
The fixture uses stock build_runner 2.16.2 and analyzer 14.6.0.

- `skew`: A and B are independent; C depends on A. One input each, jobs=2,
  artificial async delays A=200ms, B=2000ms, C=1800ms.
- `balanced`: 12 inputs in A, no B/C inputs, jobs=3, no artificial delay.
- `inputs`: 12 inputs in A, no B/C inputs, jobs=3. The first three seed inputs
  each wait 2000ms; the remaining inputs and summaries wait 200ms. This deliberately
  penalizes fixed contiguous input partitions.

These artificial async waits represent uneven task durations, not CPU-bound Dart
builder work. No real-project or general speedup follows from them.

## Results

Seconds: median (minimum–maximum), n=3. Change is ready relative to wave;
a negative value means less elapsed time.

| Profile | Case | Wave | Ready | Change |
| --- | --- | --- | --- | --- |
| skew | clean | 13.571 (13.300–13.622) | 9.601 (9.087–9.976) | -29.3% |
| skew | noop | 5.022 (4.431–5.227) | 5.270 (4.110–5.722) | +5.0% |
| skew | one-file | 8.808 (8.103–9.790) | 8.387 (8.317–9.913) | -4.8% |
| skew | broad | 13.678 (13.348–14.816) | 9.952 (9.162–13.118) | -27.2% |
| balanced | clean | 7.398 (7.145–8.001) | 6.892 (6.189–7.602) | -6.8% |
| balanced | noop | 4.363 (4.177–4.718) | 4.567 (4.319–4.680) | +4.7% |
| balanced | one-file | 5.939 (4.676–12.922) | 5.363 (4.876–8.425) | -9.7% |
| balanced | broad | 6.477 (5.998–7.080) | 7.095 (5.656–8.798) | +9.5% |
| inputs | clean | 14.637 (12.917–14.643) | 9.993 (9.393–11.090) | -31.7% |
| inputs | noop | 4.313 (3.794–4.464) | 3.640 (3.598–4.258) | -15.6% |
| inputs | one-file | 8.337 (7.786–9.636) | 8.055 (6.959–9.793) | -3.4% |
| inputs | broad | 13.485 (13.265–16.791) | 11.004 (9.739–11.309) | -18.4% |

The skewed clean/broad cases decrease about 27–29%; skewed inputs decrease about
18–32%. Balanced broad editing has a **9.5% slower median**, with overlapping
ranges. No-op and one-file results are mixed and noisy; these three repetitions
do not establish a general improvement or absence of overhead. Package switches,
resolver hydration and extra input dispatch can outweigh reduced idle time.

Separate correctness histories prove actual readiness release: with jobs=2,
B's seed ran from 0 to 2025ms; A's two seeds completed by 452ms; C started at
600ms and finished at 2410ms. Thus C started after A completed while B was still
running. Process identifiers and builder start/end intervals, rather than the
`workers_active` counter, establish concurrency. This diagnostic run was not
included in timing samples.

The three workspace correctness scripts also passed clean/no-op/edit/delete/
rename/failure/recovery comparisons, dependency-generated imports, package/target
options, jobs bounds, worker exit rollback and disabled-shared-store coverage.
Global phase barriers and related-target ordering remain conservative. See
[ADR 0046](../../adr/0046-workspace-action-scheduler.md) for scheduler invariants.
