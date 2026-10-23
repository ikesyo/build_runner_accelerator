# Reproducible distribution validation

The release binds one source commit to the native archives, signed manifest,
and the Dart package. It retains tagpr's generated versions/changelog and the
publication order: signed GitHub Release first, pub.dev second.

## Verification order

1. Check source identity before builds. For publication, the release tag,
   checked-out commit, workflow caller SHA and caller tag ref must agree.
   `source_ref` is resolved separately and cannot select a different commit.
   Gate code is always checked out at the immutable caller SHA.
2. Run locked Rust tests and Dart minimum/current package checks in parallel.
   The current Dart lane runs `dart pub publish --dry-run`. Subsequent native
   and publication checkouts use the immutable caller SHA, which the source
   gate verifies against the tag and optional source_ref.
3. Build with `cargo build --locked --release` in the existing five lanes.
   Package using `scripts/package_frontend.py`, including VERSION and
   SOURCE_COMMIT. Each lane runs `scripts/distribution_e2e.py` on its actual
   archive before uploading it for signing. A failure blocks publication.
4. Require successful **push or workflow_dispatch** `ci.yml` for the exact
   source SHA, including its correctness and native-distribution lanes. A PR
   merge commit or another commit's success is insufficient. Builds may overlap
   running CI; before signing, Release waits up to 30 minutes (15-second polls)
   without rerunning the suite. A completed unsuccessful run fails immediately;
   no run or a still-running run at the deadline also fails.
5. Assemble the complete five-target manifest. Check each archive's version and
   source metadata, and include `source_commit` and release-source.json (the
   accepted correctness run URL/ID). Sign manifest and SHA256SUMS with Ed25519,
   retaining private-key normalization and the production public-key equality
   check. SHA256SUMS also covers source evidence.
6. Use the actual Dart downloader to verify/install all five unchanged archives
   against the final signed manifest and the package's production public key.
   Verify the checksum signature and every listed digest, then smoke-test the
   installed Linux x64 binary. Recheck source and correctness before
   `gh release create --verify-tag`.
7. Publish pub.dev through the existing reusable publisher. Its checkout has no
   source_ref input and uses the caller's ref/SHA; this is why a publishing
   dispatch from main with a different `source_ref` is rejected. Native artifacts
   and the Dart package therefore use the same source commit.

The implementation adds steps to existing jobs, not new jobs or target matrices.
Dart/Rust checks and the target lanes preserve parallel execution. The added
critical path is approximately the slowest target's E2E plus final signed
installation checks, setup/signing overhead and any outstanding correctness-CI
wait, rather than the sum of five E2Es. Each evidence.json records
per-command and total seconds. Stock cold compilation overlaps native prewarm
inside each E2E, using independent workspaces. Runner queueing, cold package
downloads, SDK setup and signing latency must be measured separately in Actions; a local
measurement does not establish a CI duration bound.

## Workflow dry-run (no tag or production secret required)

Run CI on the candidate branch/commit and wait for success. Then dispatch
Release **at that same ref**, specifying its existing pubspec version as `tag`:

```bash
gh workflow run ci.yml --ref CANDIDATE_REF
# After CI succeeds:
gh workflow run release.yml --ref CANDIDATE_REF \
  -f tag=v0.14.1 -f dry_run=true
```

Use the candidate's version rather than copying the example after tagpr bumps
it. `source_ref` is optional; if provided, it must resolve to the caller SHA.
A dry-run validates version identity but does not require the named tag to
exist. Manual runs default to dry-run. It runs the five target lanes, aggregate
manifest/checksum creation, temporary-key signing, and final signed-artifact
installation checks.
It skips both GitHub Release and pub.dev publication. The private test key is
removed; `dry-run-signed-distribution` retains archives, signatures and the test
public key for inspection. No production signing secret is passed to this mode.

Publishing dispatches require `--ref RELEASE_TAG`, matching `tag`, and
`dry_run=false`. tagpr's existing dispatch already uses the release tag; it
explicitly selects publication mode. Tag push events also select publication.
Do not create or move tags to make a failed source-identity check pass.

## Local replay

On a matching native host with Python 3, OpenSSL 3, Dart 3.13.3, and Rust for the
**producer** step:

```bash
cargo build --locked --release --manifest-path rust/Cargo.toml
python3 scripts/package_frontend.py \
  --binary rust/target/release/build_runner_accelerator \
  --target linux-x64 --output /tmp/distribution \
  --evidence /tmp/distribution/platform
python3 scripts/distribution_e2e.py --dart "$(command -v dart)" \
  --target linux-x64 \
  --archive /tmp/distribution/build_runner_accelerator-linux-x64.tar.gz \
  --results /tmp/distribution/e2e
python3 -m unittest discover -s .github/scripts -p 'test_*.py'
```

Select the matching target/binary suffix on other hosts. Only the producer
needs Rust. The consumer runs with cargo/rustc removed from PATH, no binary
override, a disposable portable Dart package copy (lib/bin/tool and package
metadata), new workspaces, and empty pub/accelerator caches. It downloads real
packages using the existing current_json_app lockfile with
`pub get --enforce-lockfile`; only the accelerator path is relocated. Both
reference and native workspaces resolve the same packages. Stock is invoked
explicitly in its own workspace and is never an accelerator fallback.

The E2E serves the actual archive and signed manifest over local HTTPS. It
changes trust **only in the disposable copy**: an ephemeral signing public key
for per-target/aggregate dry-runs, and a local TLS CA signing a localhost
server-auth certificate. The test server requires TLS 1.2 or newer. The final production-sign
installation check retains the package's production signing key. TLS hostname
and certificate checks and signature, version, protocol, length, digest, extraction and cache
checks remain enabled. No test key, HTTP exception or trust override is added
to the shipped launcher. macOS uses the runner's Homebrew OpenSSL 3 for Ed25519.

The normal `dart run build_runner_accelerator` entrypoint must download the
manifest, signature and archive exactly once during prewarm, with no generated
outputs. Initial build, no-op (including native no-work reporting and unchanged
output mtimes), an input type change, and native watch regeneration compare
nonempty output file sets and bytes against stock. Watch logs live outside the
watched tree and watch processes are cleaned up on success/failure.

Actions retains `distribution-ci-*`, `distribution-release-*`, and
`distribution-production` evidence artifacts: command logs, resolved lockfiles,
output digests, HTTP request paths, archive/source identity and timings.
Producer evidence includes runner image/OS, Linux ldd/readelf output, or macOS
sw_vers/otool output. A result is successful only when evidence.json says
`result: passed`. This small distribution fixture complements the full
correctness suite; it is not another supported-builder compatibility matrix.

## Platform facts and unverified minimums

| Target | Configured build/test host | Scope after a successful lane |
| --- | --- | --- |
| Linux x64 | ubuntu-24.04 | GNU/glibc binary, execution on this runner; not musl/Alpine support |
| Linux arm64 | ubuntu-24.04-arm | Same scope on native arm64 |
| macOS arm64 | macos-14 | Execution on that image; otool records the binary deployment target |
| Windows x64 | windows-2022 | Execution on that image; not the oldest supported Windows release |
| Windows arm64 | windows-11-arm | Execution on native Windows 11 arm64 |

Ubuntu 24.04's glibc baseline is 2.39. Do not infer an older supported glibc
version from the Rust toolchain minimum. Each produced ELF's highest imported
GLIBC symbol is recorded in build-platform.json; this is an observed symbol
requirement, not proof that all transitive runtime requirements work on that
oldest distribution. Older Linux/glibc images, musl, minimum macOS and Windows
versions, and minimum Dart execution on every OS remain unverified. The Dart
SDK package checks at 3.11.0/3.13.3 are separate from distribution E2E at 3.13.3.

OS code signing, notarization and Authenticode remain separate release gates.
Locked dependencies and immutable source identity do not claim byte-for-byte
reproducibility across compilers, runner image updates, or archive timestamps.
