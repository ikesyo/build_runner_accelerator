# ADR 0064: Evaluation matrix and distribution gate

Date: 2026-09-06
Status: Accepted

## Decision

The evaluation contract has three dimensions: target platform (linux, macos, windows), Dart SDK path/version, and workspace profile. scripts/evaluate_aot_matrix.sh records every requested cell as TSV. It executes only cells matching the host OS; other cells are explicit skipped/not-local-host, not emulated results. This keeps the matrix portable to CI runners while keeping local evidence honest.

The Linux loop covers the current JSON workspace and the multiple-build_extensions workspace. Additional workspaces can be selected with AOT_MATRIX_CASES. SDKs are supplied with AOT_MATRIX_SDKS (semicolon-separated paths (so Windows drive letters remain intact)). Existing correctness scripts remain the oracle; this layer composes and records them.

Distribution is a release prerequisite for CI integration. The recommended direction is a thin Dart/pub-facing launcher plus signed prebuilt Rust binaries for Linux/macOS/Windows and x64/arm64 where supported. The workspace-local Dart worker and AOT cache remain versioned by SDK/package/worker identity. Cargo/source installation is a developer fallback, not the normal user path. Homebrew/deb/rpm can follow once binary naming and update policy settle.

## Release spike before CI

1. Define pub package and command UX, minimum Dart SDK, and Rust/Dart worker compatibility.
2. Produce release artifacts, checksums, and signing for the primary OS/architecture cells.
3. Define binary discovery, cache location, upgrade/rollback, and script/kernel fallback.
4. Validate clean install on a Dart-only machine and a Rust-toolchain-free CI runner.

CI prewarm should consume the resulting release artifact; it should not become the distribution mechanism.