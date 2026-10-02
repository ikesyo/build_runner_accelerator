# External PR #75 validation and follow-up

Source: user-supplied `build_runner_accelerator-pr75-report.md`. These are
external measurements, not a rerun in this repository's verification fixture.
The tested head was `ac43a63`, compared with main `f7f4032`, before main #76
integration, ADR renumbering to 0023, and deferred training in `27e5ea5`.

## Reported conditions and results

- Large Flutter application: about 7,000 assets, 26,103 actions, 827 generated
  files. Four vCPUs, 15 GB memory, Dart 3.13.4 / Flutter 3.47.5.
- Native frontend directly, worker AOT enabled; ABBA order for main/PR builds.
  Detached training completed before the next measurement. The standalone
  `aot-prewarm` comparison used warm worker AOT and Analyzer byte stores.
- All 827 generated files matched stock bytes in every reported condition.
- Warm/no-op and manifest regeneration showed no demonstrated benefit from
  this PR. Valid manifests and warm generator kernels skip the catalog helper.

| Case | Main | Tested PR head |
| --- | ---: | ---: |
| Full cold build (two samples) | 137.6 / 134.6 s | 140.5 / 136.7 s |
| Generator kernel miss, shared helper hit (median) | 56.4 s | 53.9 s |
| Generator kernel and helper miss (two samples) | 52.9 / 60.1 s | 54.1 / 54.8 s |
| `aot-prewarm`, warm helper | 61.2 / 64.2 s | 31.6 / 30.3 s |
| First `aot-prewarm`, helper miss | 61.2 / 64.2 s | 82.6 s + 16.2 s training tail |

The first prewarm miss materially regressed: one full-workspace training
process competed with the two foreground shards. The small cold-build sample
does not establish a statistically reliable regression or absence of one.

## Disposition in the current PR

`27e5ea5` already queues helper creation until the foreground operation returns.
For `aot-prewarm`, `run_aot_prewarm` joins its analysis shards before returning;
the outer command guard then starts detached helper creation. Thus both the
kernel compiler and app-jit training start after prewarm completes. The earlier
local first-build comparison found immediate training +5.1% versus disabled,
and deferred training +0.3% (three medians per mode, two-CPU quota). That local
result does not predict timings for this larger external application.

The report follow-up adds direct regression coverage of two full-scope shards:
both shard completion markers and `AOT prewarm ready`/cache-key output precede
the helper creation marker. The training pass still uses shard 0 of 1 without
a directory restriction. A separate test retains `--dirs none` for summary-only
prewarm. These use an instrumented helper to verify scheduling and arguments;
they are not performance measurements of large-workspace analysis.

Full-workspace training is retained rather than unconditionally forcing
`--dirs none`: the report measured full analysis at 81.3 s from source, 63.2 s
from kernel, and 41.5 s from trained JIT with a warm byte store. Restricting
training could sacrifice that benefit and needs its own comparison. Users
can set `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_DIRS=none` to limit both
foreground prewarm and its training, or
`BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT=0` to suppress helper training.

## Limits and remaining cost

- Deferral moves training out of this command's foreground critical path; it
  does not eliminate the extra full-workspace pass. It can consume CPU/memory
  after command exit and contend with a subsequent or concurrent build.
- A snapshot miss leaves the first foreground prewarm on source. The large
  warm-hit speedup is conditional on a valid trained artifact.
- Catalog benefits are concentrated in generator-kernel misses with a valid
  helper hit. SDK/dependency updates often invalidate both tiers. Relocated
  workspaces cannot reuse app-jit helper artifacts because of bound package
  configuration locations; the generator kernel has broader sharing rules.
- The reported local artifacts total about 106.5 MB (two dill/JIT pairs), with
  another copy in the shared cache. Actual sizes depend on the workspace.
- This application is not available in the local workspace. Current-head
  large-application prewarm timings, cold byte-store prewarm, and the opt-in
  compile/manifest prewarm paths were not measured by this external report.

See [the local measurement report](helper-snapshots-2026-10.md) and
[ADR 0023](../adr/0023-helper-snapshots.md).
