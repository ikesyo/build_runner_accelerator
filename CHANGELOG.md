# Changelog

## 0.1.0 (planned)

The initial package release. This section describes the planned contents; it is not published yet.

The package has not been published yet. These entries record changes made after the planned 0.1.0 baseline.

- Reduced launcher startup overhead by removing archive, crypto, and signature
  verification dependencies from the normal import path.
- Added a lightweight release-cache hit validator with executable SHA-256
  verification; release downloading and archive installation now run in a
  dedicated isolate only on cache misses.
- Kept workspace-local worker AOT enabled by default for native launcher runs,
  with `BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0` retaining the kernel/script
  path.
- Documented that worker AOT is independent from optional user-compiled AOT
  launchers; the latter are supported only as a compatibility path.
- Added launcher-inclusive benchmark coverage for the normal `dart run`
  invocation path.

- Add the project-facing launcher and manifest generator package layout.
- Define the five-target native frontend release matrix and signed manifest
  inputs.
- Download the matching native frontend on demand after Ed25519 manifest and
  SHA-256 verification, with locked atomic user-cache installation.
- Route auto, rust, and dart launcher modes to the matching frontend and use
  the standard `dart run build_runner` fallback invocation.
- Enable the workspace-local worker AOT cache by default for native launcher
  invocations, with `BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0` as an opt-out.
- Preserve stock build_runner's `--force-aot` and `--force-jit` options in the
  launcher, including strict AOT failure behavior for `--force-aot`.
- Support Dart 3.11 and newer with a tested, bounded `build_runner` and
  Analyzer compatibility window.
- Consolidate release-facing documentation and architecture decisions into a
  concise English baseline.
