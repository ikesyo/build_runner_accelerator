# ADR 0006: Distribution and release artifacts

- Status: Accepted
- Date: 2026-09-07

## Context

Users should be able to add one Dart dependency and run a project-local
executable. Shipping Rust source would require Cargo and a native compiler;
shipping every native binary inside a Dart package would enlarge the package,
mix unrelated targets, and complicate target selection. A launcher must also
fail safely when a release artifact is unavailable or when a workspace is
outside the native manifest subset.

## Decision

Distribute one project-facing Dart package and target-specific Rust release
archives:

- The Dart package contains the launcher, manifest generator, worker runtime,
  protocol libraries, and the pinned release public key. It does not contain
  native frontend binaries.
- The launcher resolves a preinstalled binary, workspace binary, versioned
  user-cache entry, or signed GitHub Release artifact in that order.
- Release artifacts are built for macos-arm64, linux-arm64, linux-x64,
  windows-arm64, and windows-x64. Unix targets use tar.gz; Windows targets use
  zip. macOS Intel is intentionally outside the native release matrix.
- The release job publishes a versioned manifest containing target, filename,
  size, and SHA-256. The manifest and release checksums are detached-Ed25519
  signed. The launcher verifies the manifest signature, expected version and
  protocol, archive size, and archive digest before extraction.
- Cache installation uses a per-target lock, temporary files, atomic renames,
  and re-hashing of existing entries. An HTTPS mirror may be selected through
  BUILD_RUNNER_ACCELERATOR_RELEASE_BASE_URL.
- Keep release download, archive, and signature-verification dependencies out
  of normal launcher startup. The launcher validates a cache hit with the
  metadata and executable digest, and starts a dedicated downloader isolate
  only for cache misses or when the lightweight hash check cannot run.
- auto falls back to stock Dart build_runner when resolution or manifest
  support fails; rust returns an error; dart skips native resolution.
- Workspace-generated manifests, workers, graphs, SDK facades, and AOT
  artifacts are never included in a portable frontend archive.

The launcher is intentionally not an action-level proxy. It performs option
parsing, target/cache resolution, and one child-process launch, then leaves
worker IPC and scheduling to the selected frontend. A preinstalled binary
override is retained for offline use, CI, and direct performance measurement.

The supported distribution shape is a Dart script launcher invoked through
`dart run`; the package does not ship a native AOT launcher. If an advanced
user compiles the launcher with `dart compile exe`, cache-miss downloading may
use the configured Dart executable as a short-lived child process. This is a
compatibility path and does not change the worker AOT contract.

## Consequences

Normal users do not need Rust, and the Dart package remains platform-neutral.
The first native invocation may perform a network download and a cache miss
adds startup latency. A valid cache hit does not load the heavy release
dependency graph or add a second worker protocol; it only performs lightweight
metadata and executable-digest validation before the native launch.

Trust depends on the release signing key pinned in the package and the CI
secret that signs release inputs. Platform code-signing/notarization remains a
release gate to add before broad distribution. Publishing also requires a
valid repository license and a successful Dart package dry run.

## Alternatives considered

- Build from Rust source during dart pub get: rejected for user experience and
  reproducibility.
- Pack every native binary in the Dart package: rejected for package size,
  target mixing, and pub distribution constraints.
- Distribute a separate worker package: rejected because launcher, manifest,
  worker, and protocol version skew would become a normal failure mode.
- Require users to install a system binary: retained only as an advanced
  override, not the default installation path.
