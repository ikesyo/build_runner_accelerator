# Launcher and release contract

The public package is `build_runner_accelerator`. It is the single project-facing
Dart package: the launcher, manifest generator, worker runtime, and protocol
libraries are released together so the generated worker cannot drift from the
frontend contract.

## Invocation

Add the package to the target project's `dev_dependencies` and invoke the
project-local executable:

```yaml
dev_dependencies:
  build_runner_accelerator: ^0.1.0
```

```bash
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
```

The launcher consumes `--mode`, `--root`, and `--dart`. Rust frontend options
such as `--jobs`, `--interval-ms`, and `--worker` are passed to the native
frontend; other build_runner options remain Dart fallback arguments.

Mode behavior is part of the release contract:

| Mode | Native frontend unavailable | Unsupported builder manifest |
| --- | --- | --- |
| `auto` | report on stderr, then run stock Dart build_runner | report on stderr, then run stock Dart build_runner |
| `rust` | return an error | return an error |
| `dart` | always run stock Dart build_runner | always run stock Dart build_runner |

The launcher keeps stdout available to the selected build process. Its own
diagnostics are written to stderr.

## Frontend resolution

Resolution is version-pinned and ordered:

1. `BUILD_RUNNER_ACCELERATOR_BIN`;
2. `.dart_tool/build_runner_accelerator/bin/` in the workspace;
3. the user cache;
4. the matching GitHub Release artifact;
5. Dart fallback in `auto` mode.

The launcher now implements the complete release path. On a cache miss it
downloads the version-pinned manifest and detached Ed25519 signature, verifies
the signature with the public key shipped in the Dart package, validates the
target/version/protocol fields, downloads the matching archive, and checks its
size and SHA-256 before installation. No unverified network binary is
executed.

The downloaded executable and a small cache metadata file are written through
temporary files and renamed into place. A per-version/per-target lock prevents
concurrent invocations from racing on the same cache entry. Existing cache
entries are re-hashed before execution; a partial or modified entry is treated
as a cache miss. `BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL` is available for
an HTTPS-compatible mirror, while the release signing key remains pinned in
the package.

The default frontend cache is separate from workspace generated files:

```text
Linux:   $XDG_CACHE_HOME/build_runner_accelerator/<version>/<target>/
         or ~/.cache/build_runner_accelerator/<version>/<target>/
macOS:   ~/Library/Caches/build_runner_accelerator/<version>/<target>/
Windows: %LOCALAPPDATA%\\build_runner_accelerator\\<version>\\<target>\\
```

Workspace manifest, generated worker, graph, SDK facade, and AOT executable
remain under `.dart_tool/build_runner_accelerator/` and are never packed into a
portable frontend archive.

## Artifact matrix

Each release is built as six independent native cells:

| Target ID | Rust target | Archive | Runner |
| --- | --- | --- | --- |
| `macos-arm64` | `aarch64-apple-darwin` | `.tar.gz` | `macos-14` |
| `macos-x64` | `x86_64-apple-darwin` | `.tar.gz` | `macos-13` |
| `linux-x64` | `x86_64-unknown-linux-gnu` | `.tar.gz` | `ubuntu-24.04` |
| `linux-arm64` | `aarch64-unknown-linux-gnu` | `.tar.gz` | `ubuntu-24.04-arm` |
| `windows-x64` | `x86_64-pc-windows-msvc` | `.zip` | `windows-2022` |
| `windows-arm64` | `aarch64-pc-windows-msvc` | `.zip` | `windows-11-arm` |

Archives contain only the native executable, `VERSION`, and release notice
files. The publish job emits `release-manifest.json`, `SHA256SUMS`, and detached
Ed25519 signatures. The manifest records the package version, protocol major,
target, filename, byte size, and SHA-256. The launcher verifies the detached
Ed25519 signature before trusting these fields and verifies the archive digest
before extracting the executable. The signed manifest is the trust anchor for
the artifact checksum; `SHA256SUMS` and its signature remain available for
release-level consumer verification.
