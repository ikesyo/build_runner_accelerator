# ADR-0050: manifest-firstの汎用builder境界

- Status: Accepted
- Date: 2026-09-05
- Context: 任意builder対応をPoCから実運用寄りの段階へ進める
- Decision: 汎用manifest経路を正しさの本線にし、人気builder向けfast pathは独立した最適化レーンに限定する

## Context

builderをRustや共有Dart workerの静的catalogへ追加し続けると、任意builder対応のたびに
実装・依存・出力規則が増え、人気パッケージの名前が汎用action modelへ漏れ込む。
一方、build_runnerはPackageGraphとBuildConfigでbuilder import、factory、extension、
phase、build_to、optionsを既に解決している。Rust frontendがこの解決結果を受け取れば、
Rust側でbuild.yamlを再実装せず、builder packageごとの特別処理も減らせる。

## Decision

1. build_runnerの公式解決結果から、workspace固有のmanifest v2とdynamic worker entrypointを生成する。
2. manifestのbuilder IDは`package:builder`の完全な値を使う。RustのBuilderDefinition、
   action graph、worker catalogはこのIDとmanifest metadataだけを使い、freezed、
   json_serializable、riverpod_generator、source_genなどの組み込み名を分岐条件にしない。
3. outputは`output_suffixes`の配列で表し、複数出力をinput候補、dirty判定、overlay、
   output検証、atomic commit、watchの共通処理へ渡す。
4. Dart worker libraryはbuilder packageを既定カタログとして直接importしない。生成workerが
   workspaceで選択されたfactoryをimportし、worker本体はIPC・BuildStep・Resolverの共通実行だけを提供する。
5. `--mode auto`ではmanifest生成・解釈できない形状をDart build_runnerへfallbackし、
   `--mode rust`ではエラーにする。外部workerを指定する場合もmanifestのIDとIPC契約を満たすことを要求する。
6. 人気ツール向けfast pathは必須機能にしない。追加する場合はgeneric manifest pathの外側に
   分離し、同じSDK・fixture・clean/no-op/incremental条件で測定して、速度差が十分な場合だけ採用する。
   fast pathはgeneric pathの正しさの根拠やbuilder catalogの代替にはしない。

## Consequences

- 新しいbuilder packageは、worker packageやRust本体へ静的factory・extension・IDを追加せずに、
  対応subsetなら実行できる。
- worker packageから人気builderの直接依存を外せるため、依存解決と更新の結合が小さくなる。
- manifest生成時にworkspace固有のimportを解決するため、worker kernelを使う場合も生成workerとの
  不一致を避けられる。
- manifest subset外の機能は引き続きDart fallbackであり、複雑なbuild_runner互換性を早まって約束しない。
- 人気builderのfast pathは将来の性能作業として残るが、generic action modelの複雑化を招かない。

## Alternatives considered

- 既定workerへ人気builderの静的catalogを残す: 任意builder対応の本線に特別名と直接依存が残るため不採用。
- Rustでbuild.yamlを直接解釈する: build_runnerとの解釈差が増えるため不採用。
- builder factoryを反射で実行時ロードする: import、型、isolate境界が不明確になるため不採用。
- fast pathをgeneric plannerへ埋め込む: 正しさ経路と性能最適化の検証条件が混ざるため不採用。

## Verification

短い検証ループとして、Dart analyze、Rust `cargo +1.98.1 test`、および
`scripts/correctness_arbitrary_builder.sh`を使う。fixtureは2つのsource outputを
stock build_runnerとbyte比較し、2回目のRust buildがno-opになることを確認する。
fast pathを追加する段階では、この同じ比較にclean、1-file、全入力変更とmetricsを加える。
