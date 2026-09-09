# ADR 0065: Launcher package and release artifact boundary

Date: 2026-09-07
Status: Accepted (release spike; implementation in progress)

Implementation status: the first slice adds the public package layout, launcher mode/cache boundary, Rust package migration lookup, six-target archive workflow, signed manifest/checksum inputs, and local package/native smoke checks. The launcher now performs signed manifest verification, target/version/protocol validation, archive SHA-256 verification, locked atomic cache installation, and safe auto-mode fallback. Platform code signing and Dart-only clean-install CI remain pending.

## Context

The current repository is a Rust/Dart worker PoC rather than a publishable Dart
package. The Rust frontend is currently built from source by the verification
scripts, while the Dart worker package is marked `publish_to: none`. This is
appropriate for development, but it would make a normal user install depend on
Cargo, a Rust toolchain, and a repository checkout.

The release boundary must also preserve the existing split:

- Rust owns workspace scanning, planning, incrementality, scheduling, IPC, and
  atomic commit.
- Dart owns PackageGraph/BuildConfig resolution, generated worker code,
  builders, BuildStep, AssetReader, and Analyzer-backed resolver work.
- The generated worker and its AOT executable are workspace- and SDK-specific.
  They must not be treated as portable release binaries.
- CI AOT prewarm is a cache optimization. It must consume a released Rust
  frontend, not become a second distribution channel.

The project is intended to run on Dart-only developer machines and CI runners.
A Rust toolchain is useful for contributors but is not a normal end-user
requirement.

## Decision

### 1. One public, project-facing Dart package

The first public package will be `build_runner_accelerator`. It will contain:

- `bin/build_runner_accelerator.dart`: the thin launcher;
- `bin/generate_builder_manifest.dart`: the manifest generator entrypoint;
- the current worker runtime and protocol libraries;
- the launcher's binary discovery, download, cache, and fallback code.

The current `dart_worker/` package is the source of the worker portion during
the migration. It will be folded into the publishable package layout rather
than released as a second user-facing worker package. The generated worker will
import `package:build_runner_accelerator/...`, so the application has one
version to lock and one package to add.

The supported project-local setup is:

~~~yaml
dev_dependencies:
  build_runner_accelerator: ^0.1.0
~~~

and:

~~~bash
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
~~~

The launcher package depends on the worker's build_runner stack. Consequently,
the application's resolved `package_config.json` contains the worker and the
builder packages needed by the generated worker. This keeps the existing
manifest-first design intact.

A global `dart install` executable may be offered as a convenience later, but
it is not the primary v1 contract. A project-aware build tool must retain access
to the target application's package graph; a globally installed launcher alone
cannot supply that graph. The first release therefore optimizes the
project-local `dart run` path and reports an actionable error when its worker
package is absent.

### 2. Prebuilt Rust frontend, fetched on demand

The Dart launcher will never compile Rust in the normal user path. It resolves
the frontend binary in this order:

1. `BUILD_RUNNER_ACCELERATOR_BIN` explicit override;
2. workspace-local preinstalled binary under
   `.dart_tool/build_runner_accelerator/bin/`;
3. user-level binary cache;
4. the version-pinned GitHub Release artifact for the launcher package;
5. Dart `build_runner` fallback in `--mode auto`.

`--mode rust` fails with an actionable diagnostic when the binary is missing,
the platform is unsupported, the download cannot be verified, or the worker
package cannot be resolved. `--mode dart` always invokes the stock Dart path.
Auto fallback is reported on stderr and never changes the build's stdout
contract.

The download is target-specific and atomic:

- detect the process OS and architecture;
- fetch the matching versioned artifact and signed release manifest;
- verify the manifest signature using the public key embedded in the launcher;
- verify the artifact SHA-256 and expected size;
- write to a temporary file, set executable permissions on Unix, then rename;
- serialize concurrent downloads with a per-version/per-target lock.

The launcher will not use a mutable `latest` URL and will not execute a partially
downloaded file. The cache can be overridden with
`BUILD_RUNNER_ACCELERATOR_CACHE`.

The default cache layout is:

| Host | Binary cache |
| --- | --- |
| Linux | `$XDG_CACHE_HOME/build_runner_accelerator/<version>/<target>/` or `~/.cache/build_runner_accelerator/<version>/<target>/` |
| macOS | `~/Library/Caches/build_runner_accelerator/<version>/<target>/` |
| Windows | `%LOCALAPPDATA%\\build_runner_accelerator\\<version>\\<target>\\` |

This cache is distinct from the existing workspace cache at
`.dart_tool/build_runner_accelerator/`.

### 3. Release manifest and signing

Each GitHub Release publishes:

- the platform artifacts;
- `release-manifest.json`;
- a detached signature for the manifest;
- `SHA256SUMS` and its detached signature;
- source and license metadata.

The manifest contains a schema version, package/tool version, protocol major,
artifact filename, target triple, byte size, and SHA-256. The launcher trusts
only the pinned public key shipped in the package, then verifies the artifact
digest from the signed manifest. Key rotation requires a new launcher package
release.

The release package and Rust artifacts share one semantic version and release
tag. The package version is the source of the artifact tag; the launcher never
silently upgrades the Rust frontend independently of the package.

The first implementation should use a standard Ed25519 verification library
or a well-defined standard signing format. It must not shell out to a
developer-only `minisign` or `cosign` installation.

### 4. Artifact matrix

The first release builds and publishes these six cells:

| Tier | Target ID | Rust target triple | Archive | Required verification |
| --- | --- | --- | --- | --- |
| 1 | `macos-arm64` | `aarch64-apple-darwin` | `.tar.gz` | native macOS smoke, codesign, notarization |
| 1 | `macos-x64` | `x86_64-apple-darwin` | `.tar.gz` | native macOS smoke, codesign, notarization |
| 1 | `linux-x64` | `x86_64-unknown-linux-gnu` | `.tar.gz` | native Linux smoke, declared glibc floor, signed checksums |
| 1 | `linux-arm64` | `aarch64-unknown-linux-gnu` | `.tar.gz` | arm64 smoke when a native runner is available, signed checksums |
| 1 | `windows-x64` | `x86_64-pc-windows-msvc` | `.zip` | native Windows smoke, Authenticode signature |
| 1 | `windows-arm64` | `aarch64-pc-windows-msvc` | `.zip` | arm64 smoke when a native runner is available, Authenticode signature |

The first Linux artifacts are GNU/glibc artifacts. Linux musl, universal
macOS binaries, FreeBSD, RISC-V, and other targets are separate later cells;
the launcher must not label a GNU artifact as universally portable Linux.

The archive contains the frontend executable, license/notice files, and a
machine-readable version file. It does not contain a generated worker,
workspace manifest, graph, SDK facade, or AOT worker executable.

### 5. Cache boundaries

There are three independent cache classes:

| Cache | Owner | Identity |
| --- | --- | --- |
| Frontend binary cache | launcher | package version + target triple + signed artifact digest |
| Workspace generated files | target workspace | existing manifest/worker paths and package configuration |
| Worker AOT cache | target workspace/CI | existing AOT cache key: OS/arch, Dart SDK identity, manifest, lockfile, worker, and package identity |

The existing `.dart_tool/build_runner_accelerator/` layout remains the home for
the manifest, generated worker, graph, and AOT SDK facade. The AOT executable is
never copied into a cross-workspace global binary cache without its existing
metadata and dependency validation.

CI cache restore/save must use an exact AOT identity (and the AOT metadata
validation already implemented). A cache miss runs the synchronous
`aot-prewarm`, waits for completion, and saves the generated worker,
manifest, AOT executable, depfile, SDK metadata, and their cache key. CI does
not publish these workspace-specific files as release artifacts.

### 6. Release workflow

A tag release workflow will:

1. run the Rust unit tests, Dart analysis, and required correctness gates;
2. build the six Rust target cells;
3. run `--version`/help and a minimal no-op/build smoke on native runners;
4. create archives and the signed manifest/checksum set;
5. publish the GitHub Release;
6. run `dart pub publish --dry-run` and publish the Dart package;
7. run a clean-install test on a machine with Dart but no Cargo/Rust toolchain;
8. publish release notes with supported targets, fallback behavior, and cache
   locations.

Cross-compilation may produce an artifact, but it is not a substitute for a
native smoke result. Cells unavailable on the current host are recorded as
skipped rather than emulated claims. Local development and validation may stay
Linux-only; the release matrix is the CI contract.

### 7. Explicit non-goals for v1

- requiring Cargo or Rust for normal users;
- downloading the AOT worker as a release artifact;
- embedding all OS/architecture binaries in the pub package;
- using Dart build hooks to install an executable before the launcher contract
  is validated;
- Homebrew, deb/rpm, Scoop, MSI, or other native package-manager channels;
- silent fallback when `--mode rust` was explicitly requested;
- compatibility aliases for the old project name or old magic bytes.

## Alternatives considered

### Cargo/source installation

Rejected as the normal path. It is useful for contributors and an emergency
developer fallback, but it violates the Dart-only install requirement and
makes CI setup needlessly expensive.

### All binaries inside the pub package

Rejected for v1. It makes every user download every platform, increases pub
package size, couples package publication to artifact replacement, and makes
platform-specific signing/update policy less clear.

### Separate public worker package

Deferred. It preserves the current directory boundary but creates two versions
and two package identities for users to coordinate. A single public package
keeps the target package graph and worker protocol on one release line.

### Build hook as the binary installer

Deferred until a small experiment proves that an executable child process can
be safely downloaded, permissioned, discovered, and bundled by `dart install`
across all target platforms. The initial launcher download path is explicit and
testable from `dart run`.

## Implementation order

1. Create the publishable package layout and launcher entrypoint while retaining
   the current worker protocol.
2. Add target detection, binary cache, signed manifest verification, atomic
   download, and fallback.
3. Add Rust release packaging for the six target triples and native smoke jobs.
4. Add the Dart-only clean-install test and release workflow.
5. Reconnect CI AOT prewarm to the released frontend and document the final
   commands.

## References

- https://dart.dev/tools/cli-distribution
- https://dart.dev/tools/dart-install
- https://dart.dev/tools/hooks
