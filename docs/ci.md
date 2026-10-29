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
The older-runner/Analyzer 14.5 comparison reuses the Linux release frontend in
the fourth native parallel lane, keeping it off the code-generator critical path.

Compiler lanes have at most one compiler probe; shorter watch lanes also host
output-policy API/mode checks, and built_value follows DDC lifecycle. Mapping
and registry checks use other lanes. CLI checks overlap baseline work instead of waiting
for the entire baseline parallel group. SDK package checks and lifecycle probes
start together, and minimum shared-parts no longer waits for the pinned runner
lifecycle. Distribution, cache tests and AOT lifecycle probes overlap after the
release binary and root package dependencies are ready, with separate result
directories. Normal-builder AOT runs on macOS ARM64 and shared-part AOT on Linux
x64; this avoids two large AOT probes sharing the Linux runner.
The macOS probe invokes the Python comparison directly with the already built
frontend; its shell wrapper requires Bash associative arrays, unavailable in
macOS's system Bash 3.2.
Fresh stock shared-part references use JIT to check bytes; the primary
stock/native lifecycle retains the requested JIT/AOT mode. This removes
repeated AOT compilation of disposable reference workspaces. The workspace
scheduler's single-package subprobe uses a spare lane and resolver reuse follows
the shorter workspace-only probe. The standalone scheduler script still
includes both subprobes by default.

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
