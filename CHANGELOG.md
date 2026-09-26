# Changelog

## [v0.5.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.4.1...v0.5.0) - 2026-09-26

- perf: skip hidden paths in package scans by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/49
- perf: avoid duplicate Analyzer resolution across actions by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/51
- perf: share cached package asset index for tracked globs by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/52
- perf: cache conditional resolver dependencies by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/53
- perf: incrementally reset resolver state across phases by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/55
- perf: make worker AOT defaults command-aware by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/54
- perf: share analyzer byte store across workers by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/56

## [v0.4.1](https://github.com/ikesyo/build_runner_accelerator/compare/v0.4.0...v0.4.1) - 2026-09-22

- ci: show benchmark results in job summaries by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/44
- ci: capture benchmark runner fingerprints by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/45
- Reduce batch visibility memory overhead by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/47
- Investigate native action-count expansion by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/48

## [v0.4.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.3.0...v0.4.0) - 2026-09-21

- feat: support empty input extension mappings by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/32
- chore: keep fixture lockfiles synchronized with releases by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/34
- refactor(dart): split manifest model, ordering, and mapping by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/35
- fix: preserve post-process build_to source by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/36
- refactor(dart): stage manifest generation pipeline by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/37
- refactor(dart): separate worker message decoding by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/38
- refactor(dart): separate launcher and release downloader responsibilities by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/39
- test: fix empty input mapping rename fixture by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/41
- test(dart): cover manifest selection and probe boundaries by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/40

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
