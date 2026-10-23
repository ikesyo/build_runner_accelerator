# Dagger local checks

This experimental entry point runs the existing checks in Linux containers.
Install Dagger **v0.21.11** and a Linux container runtime (Docker Desktop also
works on macOS/Windows). Run commands from the repository root. No Dagger Cloud
account is required for local execution; sharing caches with CI is a separate
configuration choice. The existing CI workflows are unchanged.

## Commands

```bash
# Format, Clippy/analysis, and both unit suites in two isolated lanes.
dagger call check

# Individual unit suites; Dart uses --compiler=source, matching CI.
dagger call rust-unit
dagger call dart-unit

# Existing correctness wrapper, including its stock/native byte comparisons.
dagger call verify
dagger call verify --arbitrary-builder
dagger call verify --level=full --suites=compatibility-graph
dagger call verify --level=full

# Rerun checks even when their inputs have not changed.
dagger call check --run-id="$(date +%s)-fresh"
dagger call verify --run-id="$(date +%s)-fresh"
```

`verify` accepts the same full-suite names as `VERIFY_FULL_SUITES` in
`scripts/verify.sh`. It preserves sequential state transitions within a suite.
It does not enable benchmarks or replace `check`'s two unit suites. Errors
propagate to the CLI as nonzero exits; Dagger's progress view provides per-step
logs, including stderr. Host files and generated outputs are not modified.

## Environment and cache boundaries

- Read Dart from `.github/worker-toolchain.env` and Rust from
  `rust-toolchain.toml`; do not maintain duplicate SDK pins.
- Import source without host SDKs, Pub/Cargo build state, or local agent/cloud
  configuration. `rust/src/build` and tracked fixture outputs remain inputs.
- Build the Rust frontend once as a reusable container snapshot and supply its
  path to the existing scripts. Dart tests also receive that executable.
- Share Pub downloads and Cargo registry/Git downloads as cache volumes. Keep
  Cargo target files and test workspaces in container snapshots, so parallel
  lanes do not overwrite shared executables or fixture state.
- Resolve the root Pub lockfile before copying frequently changing sources;
  Rust builds depend on Rust sources and the shared CLI contract, so Dart-only
  edits do not invalidate them. Root dependencies use `--enforce-lockfile`.
- `check` runs at most two lanes. Internal test runners retain their existing
  worker policies; watch CPU/memory pressure before increasing concurrency.

Successful checks can be cached just like setup. A cached result means that
the same declared inputs passed previously, not that tests ran again. Change
`--run-id` for fresh execution; the value is applied after setup, so dependency
resolution and the frontend build remain reusable. This does not clear Pub or
Cargo download caches. External services, clock-dependent behavior and flaky
test investigation require a fresh run.

Do not compare a cached success against an actual test run as a speedup. The
first invocation also pays for engine/image downloads and SDK setup. Dagger
does not automatically share one machine's cache with another machine or CI.

## Evaluation

Measure these cases with the same SDKs, machine and source revision:

| Case | Command/input | What it measures |
| --- | --- | --- |
| First run | `dagger call check` on a new engine | Setup and execution |
| Unchanged repeat | Repeat the same command | Result-cache reuse |
| Fresh repeat | Change `--run-id` | Execution with warm setup |
| Dart edit | Change a Dart source, then run `check` | Dart invalidation and Rust reuse |
| Rust edit | Change a Rust source, then run `check` | Frontend rebuild and dependent checks |

Record wall time, whether test steps executed or were cached, SDK versions,
CPU/memory limits, and correctness results. Compare fresh repeats with native
host checks as well as the first and cached runs. Use an isolated checkout for
input-edit experiments and restore it afterward.

Keep performance benchmarks on the host: Docker Desktop's Linux filesystem,
watch events and scheduling do not represent native macOS/Windows execution.
Run the existing native watch and platform/release suites for those boundaries.
Containerization can reduce setup and coordination costs; no execution speedup
is assumed until measurements establish it.
