# ADR-0061: opt-in AOT worker cache

## Status

Accepted

## Date

2026-09-06

## Context

The current Dart worker can be launched as a script or from a cached kernel
snapshot. On the current JSON fixture, a standalone worker initialization
measured approximately:

| Launch artifact | Median startup + initialize |
| --- | ---: |
| Dart script | 9.49s |
| kernel snapshot | 0.178s |
| AOT executable | 0.009s |

The kernel cache already removes most Dart compilation overhead, but the
remaining worker process startup is visible on one-file incremental builds.
The current build_runner resolver also derives the SDK root from
`Platform.resolvedExecutable`. A standalone AOT executable placed directly in
`.dart_tool/build_runner_accelerator` therefore makes Analyzer look for SDK files in
the workspace's `.dart_tool` directory instead of the real Dart SDK.

## Decision

- Keep script and kernel launch behavior unchanged by default.
- When `BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1` (also `true`, `yes`, or `auto`) is set,
  automatically compile a generated `.dart` worker to an AOT executable.
- When `BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background` is set, use the existing Dart
  script worker immediately on an AOT cache miss and start an independent
  `aot-prewarm` helper. The helper waits for compilation and publishes the
  same cache atomically; later invocations use the AOT executable. A per-
  workspace lock prevents duplicate background compiles, and a failed helper
  leaves the foreground build successful and can be retried later.
- Store the generated executable below
  `.dart_tool/build_runner_accelerator/aot-sdk/bin/`, with `lib` and `version`
  symlinks to the Dart SDK. This preserves the SDK layout expected by the
  current Analyzer resolver. The symlinks are repaired against the current
  SDK on every use, so an artifact restored into a different runner path does
  not retain a stale absolute SDK path.
- Reuse the AOT executable only when the version-2 sidecar metadata matches
  the portable cache key and all recorded dependency content digests still
  match. The metadata deliberately stores logical `workspace:` /
  `package:<name>:` dependency keys instead of absolute paths. It includes
  SDK version and allowed-experiments digests because the compiler depfile
  does not include all SDK identity files. Publish the depfile and metadata
  before the executable so an interrupted update is treated as stale.
- Expose `aot-cache-key` and `aot-prewarm` commands. The former prints the
  path-independent identity after manifest generation; the latter waits for
  the synchronous AOT compile and verifies the resulting cache artifact. CI
  providers own the restore/save operation and should cache the generated
  worker, manifest, executable, depfile, and metadata together.
- Allow an already-built executable to be selected with
  `BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH`. An explicit path is not relocated or
  modified; it must already provide a compatible SDK facade.
- If the opt-in AOT compilation or SDK facade cannot be prepared, fall back to
  the existing kernel/script selection. Do not make AOT the default until the
  platform, symlink, cold-compile, and memory trade-offs are measured across
  representative workspaces.

## Consequences

The current JSON fixture's measured AOT lane had a cold `clean` time of
`26.51s`, including executable compilation. After the benchmark warm-up, the
three-repeat medians were:

| Case | AOT worker, jobs=1 |
| --- | ---: |
| no-op | 9.8ms |
| one-file | 87.7ms |
| broad | 101.7ms |

The measured generated files remained byte-identical to stock. The one-file
and broad results are substantially below the kernel-cache lane on this small
fixture, but the first AOT compile is expensive and each workspace owns its
artifact. `jobs > 1` still starts multiple Analyzer processes; AOT reduces
their launch cost but does not share Analyzer state between processes.

The SDK facade currently relies on symbolic links. Unsupported or restricted
symlink environments use the existing kernel/script fallback instead of
silently running Analyzer against an invalid SDK path. The portable CI cache
contract and example restore/save sequence are documented in
`docs/adr/0062-ci-aot-prewarm.md`.

## Verification

- Rust unit tests: 37 passed
- Dart worker analysis: no issues
- `scripts/correctness_current_json.sh` with AOT: passed
- `scripts/correctness_aot_worker.sh`: initial compile, cache reuse, source
  invalidation, and output regeneration passed
- `scripts/correctness_aot_prewarm.sh`: synchronous prewarm, relocated cache
  key, SDK facade rebind, cache reuse, and source invalidation passed
- `scripts/watch_smoke_current_json.sh` with AOT: passed
