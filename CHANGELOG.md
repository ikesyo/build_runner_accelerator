# Changelog

## [v0.12.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.11.0...v0.12.0) - 2026-10-10

- Restore analyzer 14.5 support with build_runner 2.16.2 by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/103
- Preserve CLI arguments and enforce frontend capability routing by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/105
- Remove obsolete 0.x compatibility paths and clarify disposable internal state by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/106
- Support stock build settings in the native frontend by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/107

## [v0.11.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.10.0...v0.11.0) - 2026-10-08

- feat: add setup-time prewarm with background AOT compilation by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/95
- chore: format Rust code and enforce lint checks in CI by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/97
- perf: avoid byte copies in Dart asset decoding and digesting by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/98
- perf: share immutable generated output buffers across transactions by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/99
- Deduplicate dirty output reads by resolved physical path by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/100
- Reduce Rust action planning retention with shared instances and specs by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/101

## [v0.10.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.9.0...v0.10.0) - 2026-10-07

- perf: avoid copying cached bytes during phased dependency reads by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/87
- Add frontend wall timeline diagnostics by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/89
- Investigate phase reset synchronization and retain targeted wall diagnostics by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/91
- Use immutable per-reset blobs for overlay transport by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/92
- fix: preserve analyzer compatibility with stock build_runner by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/94
- perf: reuse reset directives for identical pre-build content by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/93

## [v0.9.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.8.0...v0.9.0) - 2026-10-04

- perf: reduce resolver startup with cached directives, batched reads, and packed stores by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/73
- fix: stop duplicate packed cache growth and remove migrated legacy shards by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/76
- perf: reduce cold AOT startup by isolating trigger parsing by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/77
- perf: avoid SDK summary copy during resolver initialization by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/79
- ci: run Dart format only with the development SDK by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/81
- perf: reduce cache write overhead and make single-flight opt-in by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/80
- perf: avoid scanning unused byte-store payloads by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/82
- perf: reduce measured cold Builder asset lookup costs by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/83
- perf: reuse conditional directives and avoid declaration parsing by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/84
- perf: reuse collector SHA-256 on immutable read snapshots by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/85

## [v0.8.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.7.0...v0.8.0) - 2026-10-02

- Run full verification coverage in PR CI by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/66
- refactor(rust): split builder manifest responsibilities by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/46
- refactor(rust): split worker responsibilities by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/68
- refactor(rust): split build transaction stages by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/69
- fix(rust): preserve regenerated outputs and reconsider skipped consumers by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/70
- perf: accelerate cold manifest generation by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/71
- perf: share manifest kernels and serialize SDK summary startup by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/72

## [v0.7.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.6.0...v0.7.0) - 2026-09-29

- ci: split long PR groups and jobs to recover ~5m wall clock by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/60
- perf: reuse pristine Freezed correctness workspaces by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/63
- Reuse correctness suite baselines to reduce local verification time by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/64
- perf: follow up on v0.6.0 cold-path performance by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/61
- Reuse baselines across full correctness verification by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/65

## [v0.6.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.5.0...v0.6.0) - 2026-09-27

- perf: add v0.5.0 follow-up optimizations by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/58

## [v0.5.0](https://github.com/ikesyo/build_runner_accelerator/compare/v0.4.1...v0.5.0) - 2026-09-27

- perf: skip hidden paths in package scans by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/49
- perf: avoid duplicate Analyzer resolution across actions by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/51
- perf: share cached package asset index for tracked globs by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/52
- perf: cache conditional resolver dependencies by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/53
- perf: incrementally reset resolver state across phases by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/55
- perf: make worker AOT defaults command-aware by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/54
- perf: share analyzer byte store across workers by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/56
- perf: prime analyzer caches across builds by @ikesyo in https://github.com/ikesyo/build_runner_accelerator/pull/57

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
