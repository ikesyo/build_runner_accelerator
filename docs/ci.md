# PR CI budget and coverage

The latency target is 5–6 minutes from PR update to completed checks, including
runner queues. A PR expands to **16 CI jobs**, leaving four of the 20 concurrent
runner slots for CodeQL and other checks. This budget applies to one PR run;
other PRs, pushes and externally configured workflows can still contend for
the account's slots. Superseded runs are cancelled by PR number.

`.github/scripts/check_ci.py` checks matrix expansion, the runner budget,
the four-lane limit, and shell syntax. Run it with Python and PyYAML 6.0.3.
When changing a matrix expression, update its finite expansion check too.

## Execution layout

| Jobs on each PR | Count | Coverage |
| --- | ---: | --- |
| Dart package, SDK, Rust and Python helpers | 2 | Minimum/downgrade and current/upgrade package tests, analysis and SDK lifecycle; minimum shared parts and pinned runner; current SDK also runs Rust/Python checks, publication recovery and one dependency-window pair |
| Integration | 11 | Filter selection; filter resolver/state/unsupported; filter watch/boundaries; two configuration suites; output policies; baseline/CLI/scheduler; code generators; lifecycle/workspace; web compilers; Drift/registry/recovery |
| Native distribution | 3 | Linux x64, macOS ARM64, Windows x64; package installation and shared-cache tests on each OS |

Both SDK jobs and all eleven integration jobs use `ubuntu-24.04-arm`.
The native Linux distribution job stays on `ubuntu-24.04` to build and execute
the x64 release binary and its compatibility probes. Worker caches include
`runner.arch`, so the SDK migration starts with separate ARM64 caches.
The SDK job also declares `PUB_CACHE` at job scope, matching the cached
workspace directory despite setup-dart exporting a home-directory default.
Pinning the existing 24.04 image keeps the architecture comparison separate
from an Ubuntu image upgrade; ARM speedups must be measured for each workload.

Every integration scenario family remains on PRs. Freezed, Riverpod, optional builder
and JSON Serializable run their complete case selection once per suite, using
the scripts' existing baseline restoration instead of starting a fresh stock
and native pair for each case. Case state is restored at the same active paths,
preserving timestamps and SDK links. Failures still stop the lane.

Output policy lifecycle validation has three binary axes: verify/keep policy,
source/cache layout, and filtered/unfiltered build. PRs run a four-row pairwise
covering array instead of repeating the complete lifecycle for all eight rows:

| Layout | Policy | Filter |
| --- | --- | --- |
| source | verify | off |
| source | keep | on |
| cache | verify | on |
| cache | keep | off |

Every pair of axis settings is covered, and each row retains all existing
lifecycle, byte-equality, no-op and publication assertions. Main, manual and
scheduled runs keep the full eight-row cross product, as do local runs by
default. This defers regressions unique to an omitted three-way interaction
until full validation. `test_output_policy_matrix.py` checks the pairwise
coverage against the complete product and rejects unknown coverage modes.

Each integration job sets up Dart, the debug frontend and fixture dependencies
once, then runs up to four parallel lanes. Each comparison creates its own
temporary workspace. State transitions within a scenario stay sequential.
Watch, failure/rollback, dependency windows, workspace scheduler and stock byte
comparisons remain covered. Benchmarks stay outside PR correctness checks.

Ordinary settings, argument-spelling, config-file and validation-error
comparisons use AOT on every CI event and by default locally. These cases
exercise option resolution rather than worker compilation mode. AOT reuses
the unchanged compiled catalog across option-only changes, while the JIT
kernel is invalidated when manifest regeneration rewrites its entrypoint.
The existing compile, publication-recovery and watch probes keep their
explicit JIT/AOT choices and transitions; neither their cases nor assertions
are removed. An exhaustive second pass of every option spelling in JIT adds
no separate settings boundary, so it is not scheduled. For diagnostics,
`SETTINGS_COMPARISON_MODE=jit` still selects the complete ordinary comparisons.

The `values` group was compared locally with the same Dart 3.13.3, Rust 1.98.1
frontend and warm dependency cache, fresh stock/native roots and a fresh worker
cache per run, one native worker, and all byte comparisons enabled:

| Command prefix (followed by `bash scripts/correctness_settings.sh`) | Group time |
| --- | ---: |
| `SETTINGS_CASE_GROUP=values SETTINGS_COMPARISON_MODE=jit` | 169.8s |
| `SETTINGS_CASE_GROUP=values SETTINGS_COMPARISON_MODE=aot` | 63.2s |

Individual option-only transitions fell from about 20s to 2s in that probe.
The cold build and a catalog-changing named config still compile normally.
Case logs include mode and elapsed time so lane balancing can follow actual
work rather than hiding compilation behind extra runner slots.

Nested-package recovery actions have two independent cases. CI assigns
`NESTED_PACKAGE_RECOVERY_CASE=failure-cancel` and `builder-transition` to two
short lanes in the filter-watch and current-SDK jobs, respectively.
The default remains `all`; a unit test verifies that the split covers the
original sequence exactly once and unknown selections fail explicitly.

Filter selection and nested-package comparisons retain JIT. A controlled local
source-selection comparison took 125.4s with JIT and 148.7s with AOT, so the
broader AOT migration was not adopted. CLI comparisons also retain JIT: their
complete local probe took 112.5s with JIT and 118.8s with AOT conflict-flag
comparisons. Output bytes, invocation history, deletion and no-op assertions
are unchanged.

Short independent probes fill existing lanes: the output-policy job also runs
package smoke, scheduler reuse and named/backslash configuration watches.
Obsolete-state recovery shares the short config-files/nested-watch lane.
Current SDK lanes also run generic watch, nested builder transitions, the JSON
workspace lifecycle and runner 2.15.3 / Analyzer 13.3. The minimum SDK adds the
nested dependency-disabled lifecycle; its fixture declares Dart 3.11 support.
Both SDK jobs resolve that fixture before parallel checks so its offline
stock/native copies have all pinned dependencies available. These assignments keep all
scenarios on PRs without adding runners or splitting a scenario's state changes.

The current SDK job shares its installed Rust toolchain and Cargo cache with
the Rust/Python checks, freeing one runner slot for filter comparisons. Package
tests use the SDK's kernel compiler on the current resolution. The minimum
resolution retains source compilation: its frontend_server_client 3.2 expects
`frontend_server.dart.snapshot`, which Dart 3.11 no longer ships. Integration
workers still exercise real JIT/AOT modes. Native distribution's cross-platform
cache probes retain source compilation.
The two Analyzer-heavy subprocess helpers are compiled to SDK-local kernel
files once per package job and reused by their process tests. This removes
repeated source compilation from the tests' unchanged 30-second deadlines.
Local runs without the helper-directory environment variable keep source mode.
The readiness-marker test also publishes its JSON atomically, matching the
real publisher rather than racing an asynchronous read against file truncation.
Latest-resolution validation also caught Analyzer 14.7 removing
`nonPackageFeatureSet`. The shared analysis-options adapter sets the legacy
field only when present; 14.7 uses `contextFeatures` for package and non-package
files. Focused feature tests cover 13.3, 14.6 and 14.7 without capping upgrade
validation to an older Analyzer release.
The older-runner/Analyzer 14.5 comparison reuses the Linux release frontend in
the fourth native parallel lane, keeping it off the code-generator critical path.

Compiler lanes have at most one compiler probe; shorter watch lanes also host
output-policy API/mode checks, and built_value follows DDC lifecycle. Mapping
and registry checks use other lanes. CLI checks overlap baseline work instead of waiting
for the entire baseline parallel group. SDK package checks and lifecycle probes
start together, and minimum shared-parts no longer waits for the pinned runner
lifecycle. Distribution, cache tests and AOT lifecycle probes overlap after the
release binary and root package dependencies are ready, with separate result
directories. Normal-builder and shared-part AOT use separate parallel lanes on
macOS ARM64; x64 distribution and its dependency-window probe remain on Linux
x64. The macOS probes invoke the Python comparisons directly with the already built
frontend; its shell wrapper requires Bash associative arrays, unavailable in
macOS's system Bash 3.2.
Fresh stock shared-part references use JIT to check bytes; the primary
stock/native lifecycle retains the requested JIT/AOT mode. This removes
repeated AOT compilation of disposable reference workspaces. The workspace
scheduler's independent single-package and resolver-reuse subprobes use spare
lanes. The standalone scheduler script still includes both by default.

Linux ARM64 integration continues on every PR. Native **distribution** E2E for
Linux ARM64 and Windows ARM64 runs on main pushes, manual dispatch and the weekly
Monday 03:23 UTC schedule. Those events expand to 18 CI jobs and exercise all
five release targets. The release workflow retains its five-target gate.
This deliberately defers architecture-specific packaging regressions on those
two targets until main; OS-specific packaging remains a PR check.
macOS uses the pinned `macos-15` image in CI and release builds. The former
`macos-14` image is in its October 29 brownout and retires November 2, 2026;
see the [runner image announcement](https://github.com/actions/runner-images/issues/13518).

## Timing evidence

Baseline: [CI run 932](https://github.com/ikesyo/build_runner_accelerator/actions/runs/40696558123),
commit `a5cfb92`, Dart 3.11.0/3.13.3 and Rust 1.98.1, successful with warm caches.
Durations below come from the first and last timestamp of each downloaded job
log. They include runner setup/cleanup and exclude time queued before the first
runner log. The workflow expanded to 32 CI jobs, before external checks.

| Job | Observed duration |
| --- | ---: |
| Minimum SDK | 6m 52s |
| Current SDK | 5m 59s |
| Baseline smoke plus serial CLI | 6m 27s |
| Compiler/mapping compatibility | 6m 58s |
| Freezed lifecycle | 3m 02s |
| Freezed configuration | 3m 07s |
| Riverpod | 2m 35s |

The baseline integration runners started around 13:28:50 UTC; SDK runners only
started around 13:32:59 UTC, and minimum SDK ended at 13:39:51 UTC. Reducing job
count addresses that roughly four-minute stagger as well as execution cost.
This is evidence of staggered starts, not proof that the entire delay came
from the account concurrency limit.

Compare the draft PR's CI with that baseline before claiming a measured
5–6 minute result. The first run may populate new cache namespaces. For each
run record the source SHA, event, runner architecture, cache hit/miss, job
start/end and total workflow elapsed time. Review the slowest parallel lane,
not the sum of lanes. Rebalance only independent probes; retain the transition
and publication assertions inside each scenario. No byte-equality or throughput
claim about the accelerator follows from a CI scheduling change.
