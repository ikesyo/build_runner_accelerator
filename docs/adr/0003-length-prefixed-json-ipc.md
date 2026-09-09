# ADR-0003: length-prefixed JSON IPC と action batch を使う

- Status: Accepted
- Date: 2026-09-03

## Context

Rust frontendとDart workerを別processに分けるには、stdout上のメッセージ境界、asset readのcallback、diagnostic、複数actionの結果順序を明確にする必要がある。PoCではデータ量よりも実装の検証容易性が重要である。

## Decision

- IPCは4-byte big-endian payload length + UTF-8 JSON objectのframeとする。
- Dart stdoutはframe専用にし、人間向け診断はstderrへ出す。
- Rustは`initialize`、`reset`、`build`、`build_batch`を送り、Dart workerは`asset_request`とbuild resultを返す。
- 単一workerで複数の独立actionを処理する場合は`build_batch`でまとめる。複数worker時はaction単位でwave実行する。
- v1ではoutput bytesをJSONのinteger arrayで運ぶ。大きな生成物を対象にする前にbinary side channelまたはchunkingを導入する。

## Consequences

- frame境界をnewlineやログ出力に依存せず、protocol errorを検出しやすい。
- JSON配列のbytes変換とasset RPC往復が、性能上の主要な測定対象になる。
- protocol v1の受信側は未知フィールドを無視できるよう維持し、後方互換の拡張余地を残す。

## Alternatives considered

- newline-delimited JSON: payload内のnewlineやstdout混入に弱い。
- RustからDartへの共有filesystemだけで連携する: asset readやBuilderの途中状態を表現しにくい。
- 最初からbinary protocolにする: 大規模生成物には必要だが、最小PoCのデバッグ容易性を下げる。

