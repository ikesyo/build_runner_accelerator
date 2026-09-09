# AGENTS.md

## Project overview

`build_runner_accelerator` is a Rust frontend PoC for `build_runner`. Rust owns the
filesystem snapshot, incremental action graph, phase orchestration, overlay,
and atomic commit. A Dart worker continues to execute Dart builders,
`BuildStep`, `AssetReader`, and Analyzer-backed resolver work.

Read these files before making a non-trivial change:

- `README.md` — current scope, commands, and known limitations
- `docs/roadmap.md` — persistent task list and intended implementation order
- `docs/adr/README.md` — architecture and compatibility decisions
- `protocol/v1.md` — Rust/Dart IPC contract

## Invariants

- `build_runner` compatibility is the primary constraint. Generated outputs
  must be byte-identical to stock `build_runner` where the Rust frontend is
  enabled for the supported manifest subset. Popular packages are validation
  fixtures, not built-in Rust/Dart catalog entries.
- No-op, incremental, delete, rename, failure, dependency, glob, and watch
  behavior must remain covered by correctness tests.
- `--mode auto` must conservatively fall back to Dart `build_runner` for an
  unsupported package or configuration. `--mode rust` must report an error
  instead of silently using an incompatible implementation.
- Rust stdout and the Dart worker stdout are reserved for framed IPC. Human
  diagnostics belong on stderr.
- Successful builds commit outputs and the graph only after all dirty actions
  succeed. Do not weaken the existing overlay and failure-recovery behavior.
- Same-phase generated outputs are hidden from the action that owns them;
  source outputs are exposed to later phases through the overlay and a
  resolver-only phase reset, without restarting the resident worker.
- Binary asset-read and build-result capabilities are required by the current
  development protocol; do not reintroduce JSON fallback without a new ADR.
- The default path is manifest-first: a workspace-specific worker catalog is
  generated from official build_runner configuration. Arbitrary builder
  support remains limited to the documented subset until its dedicated fixture
  comparisons are expanded. Custom worker executables must accept the same
  manifest builder IDs and IPC contract.

## Builder additions

Adding a builder should not be implemented as another isolated special case in
`main.rs`. Extend the shared builder-definition/action model first. A builder
addition normally touches all of these areas:

1. Rust builder definition and `build.yaml` subset handling
2. input/output extension and `build_to` mapping
3. phase ordering, required inputs, output validation, graph, and deletion
4. generated worker manifest/catalog and the dynamic manifest generator; a popular-tool fast path, if added, must stay isolated from the generic path
5. a small tracked fixture with stock-vs-Rust output comparison
6. incremental, failure, watch, and benchmark coverage

`freezed` and `riverpod_generator` are implemented and verified. Arbitrary
builder dynamic loading is manifest-first: use the generated-worker subset and
keep unsupported shapes on the conservative Dart fallback until the dedicated
stock/Rust comparison is complete. Do not add a popular builder to a generic
catalog as a correctness shortcut; benchmark any fast path separately.

## ADR and commit policy

Any performance, compatibility, protocol, graph, phase, scheduler, or builder
execution design decision requires a new ADR and its implementation in the
same commit. Do not rewrite an old ADR; add a newer ADR when a decision is
replaced. Mechanical refactors and typo fixes do not need an ADR unless they
also change behavior or a design boundary.

## Verification

Use the same toolchain and cache for a comparison. The scripts accept
`DART_BIN`, `CARGO_BIN`, `PUB_CACHE`, `RUSTUP_HOME`, and `CARGO_HOME` overrides.

At minimum, run:

```bash
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
```

Before merging a behavioral change, run the full suite and the relevant
benchmark/correctness fixture:

```bash
VERIFY_LEVEL=full bash scripts/verify.sh
bash scripts/watch_smoke.sh
bash scripts/correctness_freezed.sh
bash scripts/watch_smoke_freezed.sh
bash scripts/benchmark_freezed.sh
bash scripts/correctness_riverpod.sh
bash scripts/watch_smoke_riverpod.sh
bash scripts/benchmark_riverpod.sh
bash scripts/benchmark_matrix.sh
```

For performance work, record clean, no-op, one-file, and broad incremental
cases together with the command, SDK versions, worker count, and whether
outputs were byte-identical. Use `BUILD_RUNNER_ACCELERATOR_METRICS=1` when worker or
IPC behavior is part of the hypothesis.

## Repository changes

Keep changes small and preserve unrelated user work. Do not move the default
branch or push remote changes unless the user explicitly authorizes it. In the
final handoff, report the commit, verification commands, and any known
environment-dependent limitation.
