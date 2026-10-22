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
  outputs, the `build_extensions: {"": [...]}` all-asset mapping, and the
  supported post-process subset.
- Runtime post-process input mappings for applications with resolved options,
  including overrides of legacy declared extensions, input selection changes,
  stale-output cleanup, and no-op behavior.
- Runtime expected-output mapping probes for selected applications that
  need runtime data (including multi-factory and option-dependent builders),
  phase-aware generated-input visibility, and resident-worker Builder/Resource
  lifetime coverage.
- An isolated supported subset for the official
  `preparing_builder` → `drift_dev:analyzer` → `drift_dev:modular` chain at
  the pinned Drift versions, including `discover`/`analyzer` factories,
  `.dart`/`.drift` runtime mappings, analyzer cache artifact visibility,
  modular `.drift.dart` source outputs, Resolver/BuildStep APIs, stale-output
  cleanup, atomic failure recovery, and native watch.
- The official `drift_dev:not_shared` source builder and complete
  `driftCleanup` input set at the same pinned Drift versions, including stock's
  logical-delete/physical-cache distinction, intermediate visibility,
  byte-identical lifecycle output, atomic recovery, and native watch.
- Stock virtual primary IDs with normal suffix/scoped action semantics and
  unreadable asset visibility. An isolated Conduit registry configuration uses
  a fixture-only Analyzer override for stock/native byte, lifecycle, ordered
  enumeration, atomic recovery, and paired watch comparisons.
- Demand-driven execution for compatible normal `is_optional` builders when a
  later action reads or uses their declared output.
- Stock-vs-native output comparisons for clean, no-op, incremental, failure,
  deletion, rename, and watch cases.
- A single project-facing Dart launcher with automatic signed native artifact
  download and explicit native-only execution.
- Five release targets with manifest, signature, checksum, and cache
  validation.

## First-release gates

- [x] Add the repository license and make `dart pub publish --dry-run` pass.
- [ ] Configure the release signing secret and publish a tagged test release.
- [x] Implement locked release builds/tests, same-commit correctness/source/tag
  gates, and a non-publishing workflow dry-run. Replay via the
  [distribution validation guide](distribution-validation.md#workflow-dry-run-no-tag-or-production-secret-required).
- [x] Add signed-archive Dart-only consumer E2E to the existing five target lanes:
  prewarm, initial build, no-op, incremental and watch with stock byte comparisons.
  [Local replay and evidence](distribution-validation.md#local-replay) distinguish
  implemented checks from platform runs that still need execution.
- [ ] Record a successful five-target workflow dry-run on the candidate commit
  and retain its distribution evidence; local Linux evidence alone is insufficient.
- [ ] Add macOS code signing/notarization and Windows Authenticode gates.
- [x] Exercise packaged frontends through launcher prewarm/cache in the
  distribution lanes; replay with `scripts/distribution_e2e.py` as documented
  [here](distribution-validation.md#local-replay). This does not claim that a
  public tagged release has been exercised.
- [ ] Re-run the release matrix against the supported Dart SDK range and
  record the exact compatibility window.

## Post-release research

The next compatibility milestone is integration coverage beyond the validated
optional/post-process and Drift builder chains:

- [x] Resolve option-dependent post-process input extensions from the configured
  runtime factory, with stock comparisons for mapping changes and cleanup.
- [x] Validate optional producer chains with post-process cleanup, including
  source/cache outputs and incremental, failure, and watch lifecycle behavior.
  See [ADR 0038](adr/0038-optional-post-process-demand.md) for the execution rules
  and the [fixture guide](../fixtures/optional_cleanup_app/README.md) for coverage.
- [x] Extend the pinned Drift fixture to `not_shared` and the full
  `driftCleanup` runtime input set. Compare stock/native lifecycle bytes,
  intermediate visibility, logical cleanup, atomic failure recovery, and watch.
  See the [fixture guide](../fixtures/drift_analyzer_app/README.md).
- [x] Validate Conduit's real `registry_builder` in an isolated fixture using
  an explicit Analyzer 14.5.0 override with stock/native build_runner 2.16.2.
  See the [override fixture](../fixtures/registry_builder_override_app/README.md)
  for configuration, byte comparisons, virtual-input scope and visibility,
  ordered enumeration, source/cache lifecycle, atomic recovery, and paired watch.
- [ ] Resolve Conduit's published dependency constraints with a dependency
  solution compatible with the native baseline. Published
  `conduit_build_runner` 6.0.0/7.0.0 require Analyzer 12, while stock
  build_runner 2.16.2 requires Analyzer 14.3 or newer. The
  [stock-only fixture](../fixtures/registry_builder_app/README.md) records the
  7.0.0 contract on stock 2.14.1 and checks both dependency conflicts in CI.
  Keep the fixture-only override distinct from an ordinary supported package
  solution. Other Conduit generators and full project workspaces remain
  unvalidated; do not widen production constraints based on this probe.
- [x] Validate published `build_web_compilers` 4.8.12 with build_runner 2.16.2,
  build 4.0.11 and Analyzer 14.6.0, without overrides, on Dart 3.13.3: a single
  package using dart2js `-O1`, dev configuration, `generate_for: [web/**.dart]`,
  `filter_outputs: true`, and AOT paired watch. See the
  [fixture guide](../fixtures/build_web_compilers_app/README.md) for raw public
  JS/map equality, generated module dependencies, cleanup and atomic recovery.
- [x] Validate the minimal published DDC chain at the same pinned versions:
  single root package, `compiler: dartdevc`, dev, `generate_for: [web/**.dart]`,
  AMD defaults and hot reload disabled. See the
  [DDC fixture](../fixtures/build_web_compilers_ddc_app/README.md) for the full
  public kernel/module/bootstrap/SDK artifact set, raw bytes, optional demand,
  ordered inputs, compiler failure/atomic recovery and AOT paired watch.
- [ ] Validate other web compiler modes/configurations and versions: DDC hot
  reload, library bundles/frontend server and nondefault compiler flags,
  dart2wasm, release/deferred outputs, the default dev extractor's exposed
  `.deps`, cold script-worker watch, and multi-package workspaces. Retained
  compiler archives contain time and scratch/SDK paths and are not raw-byte
  identical; this probe does not claim otherwise.

- [ ] Expand the manifest subset toward complete `build.yaml` semantics while
  preserving explicit rejection outside the validated subset. Full post-process behavior and
  workspace semantics remain separate follow-ups.
- [ ] Compare conditional import/export dependency selection with stock
  `build_runner` before attempting a more precise invalidation rule.
- [ ] Evaluate chunked build-result frames for outputs beyond the v1 frame
  limit.
- [ ] Re-evaluate indexed/lazy graph persistence and automatic worker-count
  selection using reproducible benchmarks.
- [ ] Validate resolver-aware batching on larger mixed-builder workspaces before
  changing the default worker count.
- [x] Probe the root Dart CLI package of FVM at a fixed commit with published
  dart_mappable_builder 4.10.0 and build_version 2.2.1: introduced dependency
  solution, stock/native initial/no-op/model edit and paired watch, complete
  public file sets and raw bytes. See the [FVM replay](probes/fvm/README.md)
  for the upstream-to-introduced dependency changes and the shared literal
  filename suffix fix. This does not validate FVM's old lock on native,
  other commits/solutions/options, nested projects or Flutter runtime tests.
- [ ] Validate additional mixed builders and multi-package workspaces from
  real projects beyond the pinned single-root FVM probe.
- [ ] Consider builder-specific fast paths only when they beat the generic
  manifest path under the same fixture and SDK conditions.

## Verification policy

Use one Dart SDK, Rust toolchain, and pub cache for both stock and native
comparisons. The repository scripts accept `DART_BIN`, `CARGO_BIN`,
`PUB_CACHE`, `RUSTUP_HOME`, and `CARGO_HOME`.

The minimum checks are:

```bash
cargo test --locked --manifest-path rust/Cargo.toml
cargo build --locked --manifest-path rust/Cargo.toml
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
git diff --check
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

The Drift analyzer compatibility work has not been benchmarked. In particular,
small analyzer targets may be dominated by launcher, resident-worker startup,
and IPC fixed costs, so no performance improvement is implied by the
compatibility probe.
