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
Do not share mutable scenario state or relax assertions and deadlines to
hide scheduling or setup problems.

## Verification and measurement

Run `python3 .github/scripts/check_ci.py` with PyYAML 6.0.3 after workflow changes.
It checks matrix expansion, the PR runner budget, the four-lane limit and
embedded Bash syntax. Update its finite expansion logic when adding a matrix
shape, and run the relevant workflow/helper tests.

Validate changes on GitHub Actions. Record the source SHA, toolchains, runner
architecture, cache state, queue delay and longest lane alongside whole-workflow
time. Compare equivalent workloads and distinguish cold-cache results from
warm-cache results. CI timing changes alone do not establish accelerator
throughput improvements.

Keep run links, measurements, experiments and migration history in the PR
description. Keep this document focused on policies that future changes should
preserve.
