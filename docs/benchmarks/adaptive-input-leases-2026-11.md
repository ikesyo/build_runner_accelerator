# Adaptive input lease comparison (2026-11)

Two user reports bisected a large single-package regression to the shared
adaptive input queue, whose current work target is 100ms. This comparison evaluates the concrete sizing alternatives and
the combined policy in [ADR 0049](../adr/0049-adaptive-lease-work-target.md).

## Conditions

- Linux x86_64, cgroup CPU quota 2 cores; Dart 3.13.3, Cargo 1.98.1.
- build_runner 2.16.2, build 4.0.11, Analyzer 14.6.0; shared analysis byte store
  enabled.
- Release native frontends, JIT Dart workers, identical Dart worker sources and
  dependency lockfiles for all variants. Stock is an untimed byte reference.
- One sample per case. Compiler and analysis caches retained after untimed
  preparation; clean resets native graph and generated artifacts. These are
  warm-cache measurements, not fully cold/AOT measurements.
- Metrics and action histories disabled during timing; separate diagnostics.
- `single-large`: 2,048 inputs / 4,096 actions, jobs=2, 25ms artificial delay
  per action; the second phase resolves generated Dart libraries.
- `single-inputs`: 12 inputs, jobs=3; three seed actions take 2s; all other
  actions, including the summary phase, take 200ms. This exercises skew within
  one application.

## Policies

| Variant | Policy |
| --- | --- |
| baseline | Existing 100ms round-trip target, maximum 16 inputs, proportional tail cap |
| candidate | Proportional size bounded by 2s of worker-reported action time; learn from the slowest action; no fixed input-count cap |
| two_seconds | Only raise the existing round-trip target to 2s; retain maximum 16 |
| proportional | `max(1, remaining / (2 * workers))` without time restriction |
| balanced | Fixed `ceil(total / workers)` slices, matching the old balanced split |
| uncapped | Existing 100ms round-trip target with only the 16-input maximum removed |

All policies retain the same worker lifecycle, resolver limits, phase contexts
and output publication. Each experimental binary was checked by SHA-256 to
avoid reusing a different variant's Cargo artifact.

## Results

| Policy | Large clean (s) | Large broad edit (s) | Skewed clean (s) |
| --- | ---: | ---: | ---: |
| Existing | 81.797 | 80.256 | 7.355 |
| Combined policy | 64.106 | 63.269 | 7.349 |
| 2s target only | 64.732 | 63.767 | 8.245 |
| Proportional only | 62.081 | 63.543 | 9.797 |
| Balanced split | 62.012 | 62.748 | 10.145 |
| Remove count cap only | 76.831 | 78.412 | 7.554 |

Every measured clean, no-op, one-file and broad-edit result in this run was
byte-identical to stock, including source and cache outputs. No-op checks also
verify unchanged graph bytes and no executed actions.

For the large profile, existing/combined no-op times were 0.214/0.216s and
one-file times were 1.622/1.369s. These small differences should not be treated
as statistically established gains or regressions.

These synthetic actions do not reproduce the private workloads' fixed batch
cost. One sample cannot establish small differences between policies or a
universal speedup. The private sources are unavailable; their reported cold
build improvements have not been independently reproduced here.

## Separate IPC diagnostics

| Policy | Build-result frames | Bytes sent |
| --- | ---: | ---: |
| Existing | 2,086 | 237,727,517 |
| Combined policy | 145 | 18,535,478 |
| 2s target only | 287 | 34,460,998 |
| Proportional only | 54 | 8,707,451 |
| Balanced split | 4 | 3,148,620 |
| Remove count cap only | 2,317 | 270,016,896 |

These counts are from separate instrumented broad edits. They are not inferred
from the timed builds; enabling diagnostics can affect adaptive observations.

## Decision

Choose the combined policy. Pure proportional and balanced dispatch amortize
fixed cost well; the action-time upper bound retains protection after slow
inputs are observed. Raising the old target alone leaves a fixed sixteen-input
ceiling and continues learning from overhead-contaminated timings. Removing
only that ceiling leaves the short time target as the bottleneck.

Queue regression tests supply 2ms action timings for 3,163 and 26,000 cheap
inputs while varying fixed lease overhead between 129ms and 5s. Both overhead
levels must use fewer than 150 leases with jobs=2/8. This bound requires action
timings; the separate missing-timing test checks conservative round-trip sizing
and does not promise fixed-overhead-independent amortization. A sixteen-second outlier in
a 39-input otherwise cheap batch must collapse the next lease to one input.
For the deterministic 26,000-input / 2ms-per-input model, worker-count arguments
2 and 8 use 53 and 143 leases respectively at either fixed-overhead level. These
are sequential queue-model counts, not concurrent scheduler counts or elapsed-
time measurements of the private project.

## Replay

The policies above can be compared with locally built binaries and the shared
benchmark script. Measurement artifacts are generated locally rather than
committed to the repository. Every variant uses the same Dart worker.

The benchmark used the repository's Dart CLI shim, located outside SDK/bin.
Optional manifest snapshots were consequently unavailable during untimed
preparation. Timed cases retained the prepared manifest and worker kernel;
these measurements do not evaluate cold manifest generation or worker AOT.
Correctness verification uses a shim inside SDK/bin for proper SDK discovery.

With local binaries for the policies above, the comparison command is:

```bash
DART_BIN="$PWD/.toolchains/dart-wrapper" \
CARGO_BIN="$PWD/.toolchains/cargo/bin/cargo" \
RUSTUP_HOME="$PWD/.toolchains/rustup" \
CARGO_HOME="$PWD/.toolchains/cargo" \
PUB_CACHE="$PWD/.pub-cache" \
python3 scripts/benchmark_workspace_scheduler.py \
  --baseline-bin /tmp/accelerator-regression-baseline \
  --candidate-bin /tmp/accelerator-regression/hybrid \
  --comparison-bin two_seconds /tmp/accelerator-regression-candidate \
  --comparison-bin proportional /tmp/accelerator-regression/proportional \
  --comparison-bin balanced /tmp/accelerator-regression/balanced \
  --comparison-bin uncapped /tmp/accelerator-regression/uncapped \
  --profiles single-large,single-inputs --repeat 1 \
  --results /tmp/accelerator-regression/final-comparison --diagnostics
```

Replay needs a fresh results directory. The binary paths above are session
artifacts, not published release downloads.

## Verification

On the original benchmark base (`5069081`), the combined implementation passed:

```bash
cargo fmt --all --manifest-path rust/Cargo.toml -- --check
cargo clippy --locked --manifest-path rust/Cargo.toml --all-targets --all-features -- -D warnings
cargo test --locked --manifest-path rust/Cargo.toml
dart test --timeout 2m --concurrency 1
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
bash scripts/correctness_workspace_scheduler.sh
bash scripts/watch_smoke.sh
bash scripts/correctness_freezed.sh
bash scripts/correctness_riverpod.sh
git diff --check
```

Rust: 206 passed, one existing ignored test. Dart: 392 passed. Verification used
the repository toolchains/pub cache, the SDK/bin Dart shim described above and
`BUILD_RUNNER_ACCELERATOR_BIN` pointing to the local release candidate.
The quick wrappers also ran Dart analysis and formatting, manifest/cache/AOT
checks, upgrade checks and trigger-builder comparisons. The scheduler comparison
includes single-package lifecycle, failure admission, worker exit/recovery and
same-phase resolver reuse. Freezed and Riverpod used their complete case groups.

An initial wrapper outside SDK/bin failed manifest-snapshot discovery; that
setup issue was corrected before rerunning both verification wrappers to success.
A first Dart unit run under competing compiler load hit its default 30s test
timeout; the complete final run above used one test worker and a 2m timeout.

The full release/compatibility matrix, Freezed/Riverpod-specific watch scripts
and private-project cold/AOT performance were not run. No release was published.
These measurements and checks were collected before the PR commit and subsequent
integration with the latest main branch.

### Integration with current main

The draft PR was rebased onto main `c5751ca` after the measurements above.
After integration, Rust tests passed (255 passed, three existing ignored tests),
Rust formatting and clippy passed, Dart analysis of `lib/src/worker.dart` passed,
and `dart test test/protocol_test.dart --timeout 2m --concurrency 1` passed all
14 tests. The full 392-test Dart run, scheduler/watch/Freezed/Riverpod groups and
performance comparison above were not repeated on the rebased tree. The performance figures above describe the original benchmark tree. The required verification wrappers were subsequently rerun as
recorded below.

### Post-rebase verification completion

Both required wrappers passed on `57efdeb`, based on main `c5751ca`, using a
freshly rebuilt v0.19.1 release frontend:

```bash
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
```

The scheduling tests also passed (five tests), including the renamed
`large_phases_with_action_timings_amortize_setup_cost`. The runtime and test
logic are unchanged from the verified commit; subsequent updates only clarify
documentation and remove measurement artifacts from the repository.

Cost learning is separate for each configured builder application, including
separate target/builder/phase queues in workspace builds. Different builders'
samples are not pooled. Conservative sizing when inputs of the same builder
have variable costs remains a real-project measurement consideration.
