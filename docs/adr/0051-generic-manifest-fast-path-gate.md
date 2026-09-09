# ADR-0051: generic manifest経路のfast path採用ゲート

## Status

Accepted

## Date

2026-09-05

## Context

任意builderの本線は、人気builderの名前をRustへ組み込むのではなく、公式の
PackageGraph / BuildConfigから生成したworkspace固有manifestをRustのaction planningへ
渡すgeneric経路である。性能上の理由だけでbuilder固有の実装を戻すと、任意builder対応の
境界と二重実装が再び増えるため、fast pathの採用条件を計測で固定する必要がある。

同じ一時workspace、Dart SDK 3.13.0、Rust 1.98.1、`JOBS=1`でFreezed 3.2.3 +
json_serializable 6.11.2を計測した。生成物は全ケースでstockとbyte-identicalだった。

| case | stock real | Rust generic real |
| --- | ---: | ---: |
| clean | 15.643s | 17.649s |
| no-op | 1.589s | 0.010s |
| 1-file | 3.060s | 9.612s |
| all-file | 3.290s | 10.027s |

metricsでは1-fileのRust `worker_initialize_us`が7.932s、Freezedの
`run_builder_us`が1.627sだった。Rustのfilesystem/graph stageは支配的ではない。
したがって、観測された遅さはFreezedのbuilder dispatchそのものより、各build commandで
起動するworkspace固有Dart workerのinitializeに由来する。

## Decision

- generic manifest経路を正しさの基準として維持する。
- この計測だけではFreezed専用fast pathを追加しない。先にworkspace固有dynamic workerの
  起動・再利用を汎用経路として短縮し、同じfixtureで再計測する。
- 初期計測時点では`FAST_BUILD_RUNNER_WORKER_KERNEL`はpackage worker executableに限られ、
  生成された`dynamic_worker.dart`には適用されなかった。その後、生成workerにも適用できる
  汎用kernel cacheをADR-0055として実装した。kernelの効果はbuilder固有fast pathの根拠では
  なく、generic worker起動短縮の根拠として扱う。
- builder固有fast pathを追加する場合は、generic経路の外側に隔離し、同一fixture・同一SDK・
  同一caseで有意なwall time差を示す。生成物、incremental、failure、watch、unsupported
  builderのfallbackが一致しない場合は採用しない。
- benchmark scriptとruntime metricsは、fast pathの採否を再現できる測定入口として維持する。

## Consequences

- builder catalogの組み込みを再導入せず、任意builderの汎用性を保てる。
- worker起動短縮がFreezedだけでなくjson_serializableや任意builderにも効く可能性がある。
- dynamic workerとpackage configの対応を壊さないkernel cacheまたはresident lifecycleが必要に
 なる場合がある。
- fast path実装を始める前に、common startup最適化後の反復測定が必要になる。

## Verification

`scripts/benchmark_freezed.sh`を次で実行し、stock/Rustの生成物比較とno-opを含めて
timingを記録する。

```bash
FAST_BUILD_RUNNER_BIN="$PWD/rust/target/debug/fast_build_runner" \
  FAST_BUILD_RUNNER_METRICS=1 JOBS=1 \
  bash scripts/benchmark_freezed.sh
```
