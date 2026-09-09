# ADR-0010: 検証tierを分け、独立correctness caseを並列実行する

- Status: Accepted (parallel correctness trial superseded by ADR-0012; quick watch default superseded by ADR-0013)
- Date: 2026-09-03

## Context

全correctness caseはstockとRustの両方でDart buildを起動するため、コード変更ごとに繰り返すには時間が長い。一方、quick checkだけでは削除、rollback、resolver依存、fallbackなどの互換性をすべて保証できない。検証の品質を保ちながら、開発ループとrelease gateを分離する必要がある。

## Decision

- `scripts/verify.sh`を検証の入口とし、`VERIFY_LEVEL`を次の3段階に分ける。
  - `quick`: Dart analyze、smoke（unit/format/byte identity/no-op）、watch smoke（当時の案。既定動作はADR-0013で変更）
  - `targeted`: `VERIFY_CASES`で指定したcorrectness case
  - `full`: quick checksに続けて全10 correctness case。必要な場合だけ`VERIFY_BENCHMARK=1`でbenchmarkも実行
- targeted/fullでは、相互にfilesystem stateを共有しないcaseを別processで最大`VERIFY_JOBS`件ずつ並列実行する案を試行した（この部分はADR-0012で置換）。
- correctness runnerはcaseごとに一意なroot package名を使い、temp directoryが分かれていてもpackage名をkeyにするstock/build_runner側のcacheや生成scriptが衝突しないようにする。
- quickは開発中の基本ゲート、fullはrelease前の互換性ゲートと位置づける。quick passをfull passの代用とはしない。
- 既存の`correctness_json_serializable.sh`は単一case実行器として残し、個別の再現・デバッグにも使えるようにする。

## Current status

- 独立fixtureと一意なpackage名を使っても、`input-delete`や`rename`が並列時だけ不安定になることを確認したため、correctness caseはADR-0012により逐次実行へ戻した。
- quickからwatch smokeを外し、必要時は`VERIFY_WATCH=1`、fullでは強制実行する運用をADR-0013で定めた。

## Consequences

- 通常の変更確認は短くなり、当初は互換性確認の全量も並列化によってwall timeを短縮できる想定だった。
- 並列実行はDart/AnalyzerのCPU、メモリ、I/O競合に加えて、fixtureが独立でも非決定性を生む可能性がある。
- quickでは検証対象が限定されるので、release前にfullを必ず実行する運用が必要になる。
- caseごとの一時fixtureを独立processで作るため、並列実行によるgraph/output汚染を避けられる。

## Alternatives considered

- 常に全caseを逐次実行する: 品質は単純だが、開発ループが長すぎる。
- quickだけを標準化する: 速いが、互換性回帰を検出するrelease gateを失う。
- 1つのfixtureを共有してcaseを並列実行する: 速く見えるが、stock/Rust状態や生成物の競合を招く。
