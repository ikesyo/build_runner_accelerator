# ADR-0062: CI AOT prewarm and portable cache identity

## Status

Accepted

## Date

2026-09-06

## Context

The first AOT worker compile is intentionally synchronous. That is useful for
local cache correctness, but it should not delay the first build in a CI job
that can prepare the artifact once and share it with downstream jobs.

The generated manifest and Dart compiler depfile historically contain absolute
workspace paths. A CI cache therefore needs an identity and metadata format
that can be restored in a different checkout directory without accepting an
artifact compiled from different worker, package, or SDK inputs.

## Decision

Provide two explicit Rust frontend commands:

```sh
scripts/aot_cache_key.sh <workspace>
scripts/aot_prewarm.sh <workspace>
```

`aot-cache-key` first ensures that the current Rust-compatible builder
manifest and generated worker exist, then prints exactly one path-independent
cache identity. `aot-prewarm` performs the same manifest preparation and waits
for AOT compilation to finish before returning success. A cache hit still
repairs the SDK facade symlinks and validates the artifact metadata.

The cache key contains these inputs:

| Component | Purpose |
| --- | --- |
| OS and architecture | Prevent incompatible executable reuse |
| Dart SDK `version` digest | Track the SDK release and revision |
| `allowed_experiments.json` digest | Track SDK compiler feature gates |
| stable builder manifest fingerprint | Track package config, lockfile, and build.yaml inputs |
| worker source digest | Track generated imports and worker code |
| stable package-config identity | Track package names, package URI, and language version |

No absolute workspace or SDK path is part of the key. The generated AOT
sidecar stores compiler dependencies as logical `workspace:<relative>` or
`package:<name>:<relative>` keys with content digests. On restore, those keys
are resolved against the current checkout and package roots. A missing,
changed, or unresolvable dependency invalidates the artifact conservatively.

The cache should include these paths:

```text
.dart_tool/build_runner_accelerator/aot-sdk/
.dart_tool/build_runner_accelerator/dynamic_worker.dart
.dart_tool/build_runner_accelerator/builder-manifest.json
```

The `aot-sdk` directory contains the executable, compiler depfile, metadata
sidecar, and SDK facade links. The Dart SDK itself is not copied into the
cache; the facade is rebound to the runner's installed SDK when the artifact
is used.

## CI sequence

After `dart pub get`, compute the key before cache restore. Restore the exact
key, run prewarm unconditionally, and save only on a miss. A downstream job
repeats the key computation and restore, then sets
`BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1` for the Rust build.

For GitHub Actions, the provider-specific adapter can follow this shape:

```yaml
- id: aot-key
  shell: bash
  run: |
    key="$(scripts/aot_cache_key.sh "$PWD")"
    echo "key=$key" >> "$GITHUB_OUTPUT"

- id: aot-cache-restore
  uses: actions/cache/restore@v4
  with:
    path: |
      .dart_tool/build_runner_accelerator/aot-sdk
      .dart_tool/build_runner_accelerator/dynamic_worker.dart
      .dart_tool/build_runner_accelerator/builder-manifest.json
    key: build-runner-accelerator-aot-${{ runner.os }}-${{ runner.arch }}-${{ steps.aot-key.outputs.key }}

- run: scripts/aot_prewarm.sh "$PWD"

- uses: actions/cache/save@v4
  if: steps.aot-cache-restore.outputs.cache-hit != 'true'
  with:
    path: |
      .dart_tool/build_runner_accelerator/aot-sdk
      .dart_tool/build_runner_accelerator/dynamic_worker.dart
      .dart_tool/build_runner_accelerator/builder-manifest.json
    key: build-runner-accelerator-aot-${{ runner.os }}-${{ runner.arch }}-${{ steps.aot-key.outputs.key }}
```

The shell scripts do not own cache storage, so the same artifact contract can
be adapted to another CI provider without coupling the Rust frontend to its
cache API.

## Consequences

- The AOT compile cost is paid in the prewarm job on a cache miss and is
  explicitly awaited there.
- Cache-hit and downstream builds avoid compiling the worker again, subject
  to metadata validation.
- Cache keys remain stable across checkout-directory changes and package
  cache roots, while SDK and worker changes produce a new identity.
- Symlink support remains a platform prerequisite. A platform without a
  usable SDK facade falls back to the existing kernel/script path.
- AOT remains opt-in until multi-SDK, multi-platform, and representative
  workspace measurements justify making it the default.

## Verification

- Rust unit tests: 37 passed
- Dart worker analysis: no issues
- `scripts/correctness_aot_prewarm.sh`: compile wait, cache-key portability,
  relocated cache reuse, SDK facade rebind, and worker-source invalidation
  passed
