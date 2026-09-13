# Changelog

## [v0.1.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.1.0-dev.1...v0.1.0) - 2026-09-13

- chore: automate releases with tagpr by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/7
- ci: automate pub.dev publishing with OIDC by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/9
- fix: support empty outputs from normal builders by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/10
- fix: align current Freezed and Riverpod compatibility fixtures by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/11
- Normalize the full compatibility verification suite by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/12
- ci: split compatibility verification and add core check by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/13
- benchmark: remeasure current build_runner baseline by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/14
- Expand build_runner compatibility coverage by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/15

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
