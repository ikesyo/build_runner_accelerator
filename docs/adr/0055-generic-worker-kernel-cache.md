# ADR-0055: generic worker kernel cache

## Status

Accepted

## Date

2026-09-05

## Context

`builder_manifest.dart`は633行・約19.5KBだが、実行されるのはmanifestが未生成または
staleになったときだけである。Freezed + json_serializableの一時workspaceでは、warmな
manifest生成は約0.9--1.1秒だった。一方、manifestが有効なRust cleanではworker initializeが
約8.1秒、SDK summaryが約4.35秒で、filesystem/graph stageは数ms未満だった。従って、Dart
manifest生成ソースを分割するだけでは、通常のbuildの支配要因を解消できない。

生成された`dynamic_worker.dart`は毎回Dart scriptとして起動され、package importsとDart
runtimeの初期化をbuildごとに繰り返していた。kernel snapshotを再利用すればbuilder名に
依存せずこの初期化を短縮できるが、worker script、package_config、builderのtransitive
importが変わったkernelを使うと、古いfactoryを実行する危険がある。

## Decision

- `--worker`を明示していない標準manifest workerが`.dart` sourceの場合、Rustは
  `.dart_tool/build_runner_accelerator/dynamic_worker.dill`を自動生成・再利用する。
- kernelは`dart compile kernel --no-embed-sources`で生成し、Dart compilerのdepfileを
  `dynamic_worker.dill.d`へ保存する。depfileの全依存pathを確認し、kernelより新しい依存が
  ある、依存が削除された、depfileが読めない場合は再コンパイルする。
- kernelコンパイルが利用できない場合は、元のDart script起動へ戻す。明示的な
  `BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL`は自動cacheより優先し、script workerにも適用する。
- builder名・package名別のRust fast pathは追加しない。kernel cacheはmanifestから生成される
  worker全体の共通起動最適化として扱う。
- 常駐daemon化やworker lifecycleの変更はこの決定に含めず、watchのworker再利用とは独立に
  検証する。

## Consequences

- 初回はkernelコンパイル分のコストがあるが、同一workspaceの後続buildではDart scriptの
  compile/startupを繰り返さずに済む。
- 一時workspaceで、script経路の1-file build約9.9秒に対し、kernel初回は約6.1秒、kernel
  cache再利用時は約2.1秒だった。`worker_initialize_us`は約8.1秒から約0.14秒へ下がった。
- depfileのmtime検証は起動前に追加されるが、worker起動・resolver初期化より十分小さい。
- cache生成の失敗時も既存のscript経路でbuildを継続できる。kernel invalidationの検証は
  source変更、package_config変更、builder transitive source変更を段階的に追加する。

## Verification

- Rust 1.98.1 unit tests: 33 passed
- `dart --suppress-analytics analyze dart_worker`: no issues
- `scripts/correctness_arbitrary_builder.sh`のexact-extension / output-conflict case
- `scripts/correctness_arbitrary_package_target_builder.sh`
- 実fixtureでkernel初回生成、cache再利用、dynamic worker変更による再生成、stock/Rust出力
  の一致を確認
