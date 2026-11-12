# CI principles

## Budget and scheduling

Target 5–6 minutes from a PR update to completed checks, including runner queues.
Keep PR CI within **16 jobs**, reserving four of the account's 20 concurrent
runner slots for CodeQL and other checks. Other workflow runs still share that
account limit. Cancel superseded runs by PR number.

Prefer parallel steps within existing jobs over new matrix entries. Share
SDK, toolchain and dependency setup, and limit each parallel group to four
lanes. Balance the longest lanes using measured durations; adding processes
can increase CPU and memory contention.

Use ARM Linux runners for general validation where measurements support it.
Keep native distribution checks on their target architecture. Pin runner images
and toolchains so comparisons do not also change the execution environment.
The workflow is the source of truth for individual test assignments.

A lightweight classification job runs before the test jobs on pull requests.
It counts separately from the 16 test jobs above. The classifier derives the
set of gated jobs a change can affect from the tree itself: workflow lanes
name the scripts they run, scripts name the fixtures and shared files they
use, and fixture path-dependencies are followed in reverse. A fixture change
therefore runs only the jobs exercising that fixture, and a harness change
fans out to every job whose suites source it. Documentation, the Dart
package tests and CI helper tests need only the always-on package jobs,
which run unconditionally as the safety floor. Product code, the workflow
and actions, the cache preparation and key helpers, and the classifier
itself always force a full run, as does anything the derivation cannot
account for: a gated job may skip only when classification succeeded and
did not list it, so failures fail safe toward running everything. Every
script and fixture must be accounted for by derivation or by an explicit
bucket in the classifier; check_ci.py enforces that partition. Push,
schedule and manual runs are always full, which keeps main's results and
cache production complete.

## Coverage

Every integration scenario family runs on PRs. Retain stock/native byte
comparisons, no-op, incremental, delete/rename, dependency, watch, failure,
rollback and publication-recovery assertions. Benchmark workloads remain
separate from correctness checks.

Split only independent scenarios. Keep each scenario's state transitions in
order, use separate writable workspaces, and ensure partitions cover the
original cases exactly once. Invalid case selections must fail explicitly.

Use JIT or AOT according to what a test verifies and measured execution cost.
Ordinary settings comparisons may reuse AOT catalogs; mode switching, startup,
watch and recovery tests must retain their explicit execution-mode coverage.
An additional compilation mode needs a distinct validation purpose.

PRs use pairwise output-policy lifecycle coverage and native distribution
checks on Linux x64, macOS ARM64 and Windows x64. Main, manual and scheduled
runs retain the full output-policy combinations and all five distribution
targets, including Linux and Windows ARM64. Release gates retain all five.
Pairwise coverage defers failures unique to omitted higher-order interactions;
reduced PR distribution coverage defers architecture-specific packaging failures.

## Setup and reuse

Resolve shared dependencies before parallel checks, especially when copied
fixtures resolve offline. Exercise both minimum and latest dependency
resolutions; avoid pinning away failures in latest-version compatibility.

Make cache paths match the directories actually used by tools. Separate
architecture, toolchain and dependency-resolution caches. A cache miss must
remain correct. Reuse compiled test helpers and prepared baselines where safe,
preserving active paths, timestamps and SDK links required by incremental tests.
Only main-branch runs save Actions caches; pull requests and other refs restore
existing compatible caches without creating branch-scoped cache entries.
Do not share mutable scenario state or relax assertions and deadlines to
hide scheduling or setup problems.

The settings and output-policy lanes batch consecutive groups through the same
correctness runner used locally. Preserve group assignments when batching;
groups share dependency preparation and explicitly configured compilation
caches, while each group owns its mutable workspace. See
[batched correctness groups](development.md#batched-correctness-groups).

## Verification and measurement

### Workflow dependencies

All four workflows are onboarded to `.github/workflows/actions.lock`, generated
by the official `github/gh-actions-lock` CLI extension. Version tags stay readable
in YAML while the lockfile records the exact commits and repository identities,
including dependencies of the shared `$/` setup action. Unlike `./`, `$/` runs
the action at the workflow's own commit and lets the generator follow its
dependencies. Reusable workflow calls are outside lockfile coverage and must
remain pinned to full commit SHAs.

After adding a workflow or changing an action dependency, run from the repository
root with an authenticated GitHub CLI:

```bash
gh extension install github/gh-actions-lock --pin v0.4.0
gh actions-lock
gh actions-lock --verify
```

If another extension version is already installed, run
`gh extension remove gh-actions-lock` and install it again with the command above
to select the version used by CI. Commit the generated lockfile with the workflow and action changes;
never edit it by hand. `gh actions-lock --verify-local` checks coverage offline,
while CI uses `--verify` to check upstream provenance as well. Verification runs
once in the current-SDK package job without adding runners to the CI budget.
Dependabot checks workflow files and composite actions under `.github/actions/*`
weekly and maintains existing lockfile entries with version updates. If an
update leaves the lockfile stale, run `gh actions-lock` and commit the regenerated
file; the CI verification step checks it without writing changes. New workflows
still need to be onboarded with the CLI.

Review changed commits as dependency updates. Investigate changes to `owner_id`
or `repo_id`, which indicate a different source repository identity. Advancing a
moved branch or partial tag requires reviewing upstream changes before running
`gh actions-lock --relock`; do not use `--accept-moved` in automation. See the
[official lockfile guide](https://docs.github.com/en/actions/how-tos/secure-your-work/lock-workflow-dependencies).

### Checks and timing

Run `python3 .github/scripts/check_ci.py` with PyYAML 6.0.3 after workflow changes.
It checks matrix expansion, the PR runner budget, the four-lane limit and
embedded Bash syntax. It also checks that case-group partitions still cover
every registered group exactly once: the group registries live in the suite
sources, and a group no lane assigns would otherwise run only in the local
gate. Update its finite expansion logic when adding a matrix shape, and run
the relevant workflow/helper tests.

Validate changes on GitHub Actions. Record the source SHA, toolchains, runner
architecture, cache state, queue delay and longest lane alongside whole-workflow
time. Compare equivalent workloads and distinguish cold-cache results from
warm-cache results. CI timing changes alone do not establish accelerator
throughput improvements.

Keep run links, measurements, experiments and migration history in the PR
description. Keep this document focused on policies that future changes should
preserve.

### Cache layout and timing reports

The shared setup action keeps Pub downloads, Cargo downloads, Rust build
artifacts and validated Dart compilation assets in separate caches. Default-SDK
integration jobs restore one complete Pub download set. The existing codegen
job is its sole main-branch writer: before its parallel checks, it resolves the
root, every tracked integration fixture package (including nested packages), and both native
and stock dependency-window resolutions in disposable workspaces. It saves only
after all resolutions succeed. Other integration jobs only restore; they never
publish their partial downloads under the common key. No job waits for the
producer in the same run. An initial miss downloads dependencies normally.

The common Pub key includes SDK/platform, all fixture specifications/lockfiles,
preparation code and the main source SHA. A compatible fallback requires the
same preparation inputs. Each main commit can refresh the immutable cache;
latest/minimum package jobs retain their distinct SDK/resolution scopes. SDK
lifecycle and shared-part fixtures remain outside the integration union, in the
SDK/native jobs: their unlocked latest solutions must not change fresh offline
integration resolutions.
Run
`python3 scripts/prepare_ci_pub_cache.py --dart /path/to/dart --offline` against
a restored Pub directory to check the entire declared set without running builders.

Integration compilation caches contain only `byte_store`, `worker-aot` and
`manifest-kernel`, under `.dart_tool/ci-compiled-cache`. They use exact keys
containing the SDK library/compiler contents, absolute SDK/checkout/Pub paths,
dependency inputs and accelerator sources, with a separate writer per job.
PRs restore main entries; only main saves. AOT metadata and manifest-kernel
dependency digests are still validated at use time. Analyzer keys include
content/language/feature identities within their SDK-summary/Analyzer namespace.
Fresh checkouts can change source mtimes without bypassing these checks.
Restored byte-store lease files are discarded during setup before any worker
uses the isolated cache: OS locks cannot be transported, and a new runner can
reuse an old PID. Pack contents and generation pointers retain their normal
validation and locking.

Worker kernels are excluded: their depfiles contain absolute paths and freshness
uses mtimes. SDK summaries remain workspace-local: stock validation tracks SDK
version and Analyzer/build_runner paths rather than all source contents. Outputs,
graphs, recovery state and local validation receipts are never persisted by the
compiled cache. Tests that explicitly select cold or SDK-lifecycle caches keep
those overrides. Cache restoration is an optimization, never a precondition.

Cargo downloads share platform/lockfile keys. Rust
artifacts use toolchain/profile/target/source keys with compatible fallback,
so a source change can save its updated build rather than repeatedly restoring
an immutable older snapshot. Cargo still checks freshness after restoration.
Cache misses remain supported. No additional runner jobs are needed.

Capture jobs and run metadata for timing comparisons:

```bash
gh api 'repos/OWNER/REPO/actions/runs/RUN_ID/jobs?per_page=100' > /tmp/ci-jobs.json
gh api repos/OWNER/REPO/actions/runs/RUN_ID > /tmp/ci-run.json
python3 scripts/summarize_ci_timings.py /tmp/ci-jobs.json --run-json /tmp/ci-run.json
```

Record cache state separately from this report. Start delay includes runner
queueing and scheduling; it is not a direct measurement of concurrency-limit
queue time. Compare the same SHA and toolchains, and repeat cold and warm runs.
