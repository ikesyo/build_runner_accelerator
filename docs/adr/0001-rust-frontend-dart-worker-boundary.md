# ADR-0001: Rust frontend と Dart worker の責務を分離する

- Status: Accepted
- Date: 2026-09-03

## Context

`build_runner` の実行時間では、ファイル走査、差分判定、依存グラフ、成果物の保存が大きな比重を占める。一方、Builder、Analyzer、Resolver、`BuildStep` の意味論をRustへ移植すると、既存Builderとの互換性リスクが急増する。

## Decision

Rust frontend は次を担当する。

- package config、filesystem snapshot、digest
- action graph、dirty判定、削除検知、phase順序
- Dart workerとのIPC
- overlay管理、成果物のatomic commit、watchとworker lifecycle

Dart workerは次を担当する。

- Builderのfactory解決とBuilder実行
- `BuildStep`、`AssetReader`、Resolver、Analyzer
- builderが実際に観測したasset readとresolver依存の返却

## Consequences

- 既存Dart builderの意味論を再利用でき、PoCの互換性リスクを限定できる。
- Rust側で高速化できるfrontend処理を独立して最適化できる。
- IPCの往復と、Rust/Dart間でのbytes表現が追加コストになる。
- Builderの種類を増やすには、Rustの選択ロジックとDart worker catalogの両方を拡張する必要がある。

## Alternatives considered

- BuilderとAnalyzerもRustへ移植する: 長期的には高速化余地があるが、PoCの最初の互換性目標に対して範囲が大きすぎる。
- 既存`build_runner`をそのまま起動する: 互換性は高いが、frontendの差分処理を測定・置換できない。

