# External PR #75 validation at head 12a08db

Source: user-supplied `build_runner_accelerator-pr75-latest-report.md`, received
2026-10-03. This report supersedes the earlier external summary. Measurements
compare PR head `12a08db` with main `ab079ec` after PR #76, including deferred
helper creation from `27e5ea5`. These are external measurements, not local
verification-fixture timings.

## Conditions

- Same large Flutter application commit: about 7,000 assets, 26,103 actions,
  and 827 generated files. Four vCPUs, 15 GB memory, Dart 3.13.4 / Flutter 3.47.5.
- Both revisions built locally and selected through path dependencies. Native
  frontend directly, worker AOT enabled. ABBA order: main, PR, PR, main.
- Prewarm measurements use warm worker AOT and Analyzer byte stores. Training
  is allowed to finish between measurements, except the explicit immediate
  follow-up build case, which intentionally overlaps training.
- Generator-kernel misses were measured in a separate ABBA series, with three
  samples per round after helper training. Every PR sample confirmed
  `artifact=jit cache=shared`.
- Host speed changed during testing; the later kernel-miss series was about
  20% slower than the earlier series. Compare revisions within a series, not
  absolute values across series or against the older report.

## Results

| Case | Main | PR head 12a08db | Interpretation |
| --- | ---: | ---: | --- |
| Warm-helper `aot-prewarm` | 37.9–43.1 s | 16.7–18.5 s | About 58% faster |
| First prewarm, helper miss | 49.1 / 42.5 s | 47.6 / 47.6 s | Prior foreground regression resolved within this sample |
| Training after first prewarm exits | None | 46.5 / 45.4 s | Full-workspace pass still consumes about one CPU |
| Warm build immediately after a repeated prewarm miss | 24.3 / 22.2 s | 25.9 / 26.1 s | About 2–3 s / 12% slower while training runs |
| Training remaining after that build | None | 14.1 / 14.1 s | Training still active after build exit |
| Generator-kernel miss, shared helper hit (median) | 44.9 s | 44.7 s | No detectable overall wall-time improvement |

All 827 generated files matched stock bytes in every reported condition.
Standalone cold, regen, warm and no-op builds showed no demonstrated material
change in this small sample. This does not negate the measured regression for
an immediate build while training is active.

### Build samples

| Case | Main R1 | PR R2 | PR R3 | Main R4 |
| --- | ---: | ---: | ---: | ---: |
| Cold | 92.5 | 90.9 | 94.6 | 89.5 |
| Regen | 25.0 | 24.9 | 25.2 | 23.7 |
| Warm, two samples | 23.5 / 23.4 | 23.6 / 23.8 | 24.4 / 24.5 | 22.5 / 22.4 |
| No-op, two samples | 1.1 / 1.0 | 1.0 / 1.1 | 1.0 / 1.0 | 1.0 / 1.0 |

Times are seconds. A valid manifest bypasses catalog generation; the report
attributes warm-series variation to host fluctuation rather than a changed
warm execution path.

### Prewarm samples

| Case | Main R1 | PR R2 | PR R3 | Main R4 |
| --- | ---: | ---: | ---: | ---: |
| First miss | 49.1 | 47.6 | 47.6 | 42.5 |
| Training tail | — | 46.5 | 45.4 | — |
| Two subsequent hits | 43.1 / 42.1 | 16.7 / 16.7 | 17.4 / 18.5 | 38.8 / 37.9 |
| Another miss | 43.6 | 44.3 | 44.9 | 38.1 |
| Immediate warm build, without waiting | 24.3 | 25.9 | 26.1 | 22.2 |
| Training tail after that build | — | 14.1 | 14.1 | — |

Deferred creation removes training from the first prewarm's foreground work.
It does not remove the extra full-workspace analysis: training uses shard 0
of 1 without `--dirs`, and remains active for about 46 seconds after exit.
Consequently, a CI sequence of prewarm followed immediately by build can be
slower despite the warm-helper prewarm benefit.

### Generator-kernel misses and correction to the earlier report

| Case | Main R1 | PR R2 | PR R3 | Main R4 |
| --- | ---: | ---: | ---: | ---: |
| Three kernel misses | 47.3 / 44.2 / 46.6 | 46.1 / 43.2 / 45.1 | 42.0 / 44.2 / 46.5 | 45.6 / 43.6 / 43.9 |

Catalog execution improves from 2.16–2.28 s to 0.26–0.30 s with shared JIT.
Manifest snapshot preparation measured 14.5–14.8 s on main and 12.2–14.9 s
on PR. The overall build difference is hidden by roughly ±2 s variation.

The earlier report's process-wait expression incorrectly treated an escaped
pipe as regex alternation. Cleanup could delete a local training directory
while its compiler was still active, mixing helper hits and misses in the
old kernel-miss series. Its claimed 2.5-second overall improvement is therefore
superseded by this corrected series. The earlier standalone helper and
prewarm measurements used a different, correct wait and were not affected,
but current-head results above are the basis for the PR performance claims.

## Verification and remaining limitations

- External testing confirmed staged kernel/JIT publication, shared restoration,
  and use by two prewarm shards on the tested head.
- Local integration additionally checks both foreground shard completion
  markers and prewarm readiness precede helper creation. Summary-only prewarm
  preserves `--dirs none`; watch training completes while watch stays alive.
  Instrumented tests establish ordering and arguments, not large-app timings.
- Full-workspace training remains enabled. Narrowing training alone or
  interrupting it when another build starts are proposals, not implemented
  behavior. `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_DIRS=none` restricts
  BOTH foreground prewarm and training; it is not a training-only switch.
  `BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT=0` suppresses helper training.
- Ordinary-build benefit is limited to paths that actually invoke helpers.
  SDK/dependency changes often invalidate both generator and helper artifacts.
  App-jit is tied to package-configuration locations and requires retraining
  after relocation; generator kernels have broader sharing rules.
- External tests did not measure cold-byte-store prewarm, opt-in compile or
  manifest prewarm, or watch deferral performance. The large application is
  not available locally; these latest results were supplied by its tester.

See [the local controlled measurements](helper-snapshots-2026-10.md) and
[ADR 0023](../adr/0023-helper-snapshots.md).
