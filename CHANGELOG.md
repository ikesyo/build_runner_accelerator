# Changelog

## [v0.3.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.2.0...v0.3.0) - 2026-09-18

- feat: support drift_dev analyzer builder by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/29
- feat: support drift_dev modular builder by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/31

## [v0.2.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.1.0...v0.2.0) - 2026-09-17

- feat: support demand-driven optional builders by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/17
- feat: align runtime output planning with build_runner by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/19
- ci: set up Rust for tagpr workflow by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/20
- fix: update Cargo.lock during tagpr releases by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/21
- feat: support build_runner trigger semantics by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/22
- ci: parallelize and deduplicate verification jobs by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/23
- ci: unify Dart worker setup and lifecycle by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/24
- refactor: use root package as Dart worker source by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/25
- refactor: remove standalone dart worker package by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/26
- Bound and shard full verification by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/27
- chore: sync README installation version from pubspec by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/28

## [v0.1.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.1.0-dev.1...v0.1.0) - 2026-09-14

- chore: automate releases with tagpr by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/7
- ci: automate pub.dev publishing with OIDC by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/9
- fix: support empty outputs from normal builders by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/10
- fix: align current Freezed and Riverpod compatibility fixtures by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/11
- Normalize the full compatibility verification suite by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/12
- ci: split compatibility verification and add core check by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/13
- benchmark: remeasure current build_runner baseline by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/14
- Expand build_runner compatibility coverage by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/15
- fix: align required inputs and artifact visibility by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/16

## 0.1.0-dev.1

Initial public preview.

### Added

- Rust frontend and Dart launcher.
- Workspace manifest generation.
- Signed release artifact verification.
- Native binaries for the initial five-target matrix.
- Reproducible correctness and benchmark tooling.

### Changed

- Use the AOT worker path by default.
- Reduce launcher startup overhead.
- Consolidate compatibility bounds and documentation.
