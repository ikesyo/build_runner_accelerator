# Roadmap

This roadmap tracks the release baseline and the small number of remaining
decisions that affect users. Commit-level experiments are intentionally not
listed here; the durable architecture is summarized in
[`docs/adr/README.md`](adr/README.md).

## Release baseline

The following are implemented and covered by the current fixture suite:

- Rust frontend and resident Dart worker with a versioned IPC protocol.
- Workspace snapshots, dependency-aware action graphs, dirty propagation,
  overlay visibility, and all-success atomic commits.
- Native watch with worker reuse.
- Manifest-first builder loading from official `PackageGraph` and
  `BuildConfig` resolution.
- Generic target/package ordering, multiple extension mappings, source/cache
  outputs, and the supported cache-only post-process subset.
- Runtime factory mapping probes for multi-factory builders, phase-aware
  generated-input visibility, and resident-worker Builder/Resource lifetime
  coverage.
- Stock-vs-native output comparisons for clean, no-op, incremental, failure,
  deletion, rename, and watch cases.
- A single project-facing Dart launcher with automatic signed native artifact
  download and conservative Dart fallback.
- Five release targets with manifest, signature, checksum, and cache
  validation.

## First-release gates

- [x] Add the repository license and make `dart pub publish --dry-run` pass.
- [ ] Configure the release signing secret and publish a tagged test release.
- [ ] Verify a clean install on Dart-only machines without Cargo or Rust.
- [ ] Add macOS code signing/notarization and Windows Authenticode gates.
- [ ] Exercise the released frontend in CI AOT prewarm/cache workflows.
- [ ] Re-run the release matrix against the supported Dart SDK range and
  record the exact compatibility window.

## Post-release research

- [ ] Expand the manifest subset toward complete `build.yaml` semantics while
  preserving the automatic Dart fallback.
- [ ] Compare conditional import/export dependency selection with stock
  `build_runner` before attempting a more precise invalidation rule.
- [ ] Evaluate chunked build-result frames for outputs beyond the v1 frame
  limit.
- [ ] Re-evaluate indexed/lazy graph persistence and automatic worker-count
  selection using reproducible benchmarks.
- [ ] Validate mixed builders and multi-package workspaces from real projects.
- [ ] Consider builder-specific fast paths only when they beat the generic
  manifest path under the same fixture and SDK conditions.

## Verification policy

Use one Dart SDK, Rust toolchain, and pub cache for both stock and native
comparisons. The repository scripts accept `DART_BIN`, `CARGO_BIN`,
`PUB_CACHE`, `RUSTUP_HOME`, and `CARGO_HOME`.

The minimum checks are:

```bash
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
```

Before a release candidate, run the full correctness suite and the relevant
watch and benchmark scripts:

```bash
VERIFY_LEVEL=full bash scripts/verify.sh
bash scripts/watch_smoke.sh
bash scripts/benchmark_matrix.sh
```

Performance changes require clean, no-op, one-file, and broad incremental
measurements together with SDK versions, worker count, command lines, and
byte-identical output results. Runtime metrics are opt-in through
`BUILD_RUNNER_ACCELERATOR_METRICS=1`.
