# ADR-0044: 事前コンパイル済みDart worker kernelによるcold start短縮

## Status

Accepted

## Date

2026-09-05

## Context

Rust 1.98.1で`JOBS=1`のbuilder matrixを3回反復した結果、Rust側のfilesystem/graph
stageは小さく、worker processのinitializeとbuilder buildが主なwall timeになった。
`worker_initialize_us`はJSONで約0.9–1.0秒、Freezed/Riverpodのclean buildで約5秒だった。
この値には`dart run`によるDart workerの起動・package loadingが含まれる。

workerの初期化frameを待つだけの比較では、事前生成したJIT kernelを
`dart --packages=<workspace>/.dart_tool/package_config.json <worker.dill>`で起動すると
約0.24秒で応答した。一方、`dart compile exe`は`build_runner_core`の`dart:mirrors`参照により
AOT compilationできない。

## Decision

- `FAST_BUILD_RUNNER_WORKER_KERNEL`が指定された場合、Rust workerはDartのkernel snapshotを
  直接起動する。
- workspaceの`.dart_tool/package_config.json`を`--packages`で明示し、workerが現在のpackage
  configを`Isolate.packageConfig`から読み取れるようにする。
- kernel指定時は`dart run`専用の`--suppress-analytics`を渡さない。
- 未指定時は従来の`dart --suppress-analytics run <package:executable>`を維持する。
- `scripts/compile_worker_kernel.sh`を標準生成入口とし、kernelは`.toolchains`配下へ保存する。

## Consequences

- cold buildではDart workerの起動・package loadingを短縮できる可能性がある。
- kernelはworker source、依存lock、Dart SDKと同じ寿命ではないため、更新後の再生成が必要。
- kernelはworkspaceのpackage configと対応するworker依存を前提とする。異なるworker catalogや
  package versionで共有してはならない。
- watchではworkerが既に常駐するため、主な効果は最初の起動とworker再起動時に限られる。
- AOT executableを採用せず、`dart:mirrors`を含む現行builder依存との互換性を保つ。

## Verification

- `dart compile kernel bin/fast_build_worker.dart`に成功した。
- kernelを`--packages`付きで直接起動し、initialized responseを取得した。
- Rust 1.98.1でbinaryを再ビルドし、unit test 29件に成功した。
- JSON / Freezed / Riverpodのmatrixを`JOBS=1`・3回反復し、byte-identicalとno-opを含めて
  全ケースに成功した。
- kernel指定経路でRiverpod benchmarkを実行し、出力比較とno-opを含めて成功した。

## Alternatives considered

- `dart compile exe`: `dart:mirrors`のため現行worker依存では利用できない。
- 毎回`dart run`を使い続ける: 互換性は保てるが、clean/cold buildの起動コストを削減できない。
- workerを別daemonとして常駐させる: 起動コストはさらに償却できるが、lifecycle・workspace
  isolation・失敗時の再接続を追加するため、kernel経路の効果確認後に再評価する。
