# Dagger experiment handoff (2026-10-23)

User request: evaluate Dagger for local verification and speed, implement a
small experiment, and create a **draft PR**. Include Rust and Dart unit tests
and document agent usage policy in AGENTS.md. The user then requested a new
session handoff before runtime validation finished.

Branch: `experiment/dagger-local-verification`, based on main `f9b5c6d`.

## Implemented

- Dagger v0.21.11 Python module with `check`, `rust-unit`, `dart-unit`, `verify`.
- `check`: at most two lanes, Rust fmt/Clippy/unit tests and Dart
  format/analyze/unit tests (`--compiler=source`).
- SDK pins read from existing repository files. Reusable frontend snapshot;
  Pub/Cargo download caches; target state is not a mutable shared cache.
- `verify` delegates to the existing wrapper, supports full suite selection
  and arbitrary-builder checks. `--run-id` forces fresh checks after setup.
- AGENTS.md policy, docs/dagger.md usage/evaluation plan, development guide
  link, and exclusion of Dagger files from the published Dart package.
- No existing CI workflow changes. A proposed scoped Actions experiment was
  put on hold when the user enabled the registry for a new session.

## Confirmed so far

- Rust host unit tests: **178 passed, 1 ignored**, command:
  `cargo test --locked --manifest-path rust/Cargo.toml` with repository
  RUSTUP_HOME/CARGO_HOME/PATH. Recorded wall time 7.150s; concurrent workloads
  mean this is not a controlled benchmark.
- Ruff format/check passed; mypy `--strict .dagger/src` passed.
- Imported against actual `dagger-io==0.21.11` and resolved all four exported
  functions' parameter annotations, DefaultPath and Ignore metadata.
- `git diff --check` passed.
- The host quick verification's smoke stage passed byte equality and no-op;
  the entire quick wrapper and Dart unit tests had not completed at handoff.

## Runtime blocker and setup

The official CLI was downloaded to `/tmp/dagger-poc/bin/dagger`; SHA-256 of
`dagger_v0.21.11_linux_amd64.tar.gz`:
`a2d3ef96e7305abc18663a3606d9c1c592278ba3c8f48e01d6be14eef72276ef`.

Docker works when commands run outside the filesystem/network sandbox
(`exec_command` with the appropriate permission request). The sandbox itself
denies the Docker socket and proxy connection. Do not interpret those sandbox
errors as broken Docker or invalid GitHub credentials.

Actual `dagger functions` could not pull `registry.dagger.io/engine:v0.21.11`:
the proxy returned **403 Forbidden**. The user explicitly authorized adding
`registry.dagger.io` and `api.github.com`, then said registry.dagger.io was
enabled. In this running environment, environment_status still returned only
storage.googleapis.com as the custom allowlist (revision 4) and another direct
registry request returned 403. Recheck in the new session, where updated
settings may apply. Do not bypass the proxy or disable TLS verification.

Read the cloud-environment-runtime skill and its Docker/network references.
Respect proxy and CA injection for the Dagger engine and nested containers;
runtime/module loading, image availability, SDK paths, and actual test
execution are **not yet validated**. No Dagger speedup is established.

## Next actions

1. Inspect branch and AGENTS.md, recheck Docker and network settings. Run
   `dagger functions`, fix any runtime/schema problems, and generate/check
   lockfiles with the official CLI as appropriate.
2. Validate individual Rust and Dart unit functions and `check`; validate
   quick correctness with and without `--arbitrary-builder`, plus one full
   compatibility suite. Use bounded concurrency.
3. Compare first, unchanged/cached, unique-run-id/fresh, Dart-source-edit and
   Rust-source-edit runs. Record actual execution versus cached successes.
   Use an isolated checkout and restore input edits. Do not claim a result
   cache hit represents faster test execution. Keep native benchmarks native.
4. Complete mandatory host checks from AGENTS.md. Address any existing test
   failures separately from orchestration failures; do not report partial
   progress as whole-suite success.
5. Review source import exclusions, immutable target sharing, failure
   propagation, toolchain setup reuse, and behavior under parallel lanes.
6. Commit fixes/evaluation evidence and create the requested **draft PR** to
   main. Git push works. `gh api` was blocked by the proxy, but connected
   GitHub tools expose `github_create_pull_request` with `draft: true`; prefer
   that tool for PR creation. No PR has been created yet.

If the same workspace survives, `/tmp/dagger-poc/results/` contains logs:
host-quick.log, host-rust-unit.log, host-dart-unit.log, dagger-functions.log.
SDK/static-check venv is `/tmp/dagger-poc/venv`. These temporary paths are not
guaranteed to survive a new session. The prior host quick and Dart-unit
processes were still running at snapshot time; inspect their completion
before starting conflicting host runs if this is the same instance.
