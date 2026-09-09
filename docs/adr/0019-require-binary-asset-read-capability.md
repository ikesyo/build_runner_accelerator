# ADR-0019: 新規PoCではbinary asset `read`を必須にする

- Status: Accepted
- Date: 2026-09-04

## Context

ADR-0017では、binary asset `read` responseを導入しつつ、capabilityを広告しない
workerにはJSON `bytes`配列でfallbackする方針を採った。しかし現在はRust frontendと
Dart workerを同時に開発している段階で、旧workerとの組み合わせを維持する必要がない。

fallbackを残すと、binary protocolの検証経路とJSON経路が並存し、性能計測でどちらが
使われたかを確認する分岐も増える。非対応workerを黙って低速経路へ送るより、protocol
契約のずれを初期化時に検出する方が、PoCの実装・検証ループに適している。

## Decision

- `asset-rpc-binary-read-v1`を現行worker protocolの必須capabilityとする。
- Rustは`initialized` responseにcapabilityがない場合、JSON fallbackせず初期化を
  エラーにする。
- 成功したasset `read`は常に単一binary frameで返し、JSON `bytes`配列経路を持たない。
- missing/error、`can_read`、`find_assets`、`build_result.outputs[].bytes`のJSON
  契約は今回変更しない。
- ADR-0017のうち「非対応workerへのJSON fallback」に関する部分は本ADRで置き換える。
  ADR-0017自体は導入時の判断履歴として保持する。

## Consequences

- read responseの実行経路が一つになり、protocol mismatchを早期に発見できる。
- fallback分岐、fallback経路の計測・テスト・保守が不要になる。
- 古いworkerや独自workerとの組み合わせは意図的に非対応になる。互換性が必要になった
  時点でprotocol versionまたはcapability方針を新しいADRで再検討する。
- `build_result`の大きな出力は引き続きJSON配列であり、binary化の次の対象として残る。

## Validation

- 現行workerのcapability確認後にbinary readだけが実行されることを確認する。
- Dart analyze/format、Rust tests、smoke/watch、correctness全10ケースを通す。
- `binary_read_responses == read_requests`、生成物のbyte identity、no-opを維持する。

## Alternatives considered

- capability非対応時にJSON fallbackする: 互換性は高いが、現在不要な二重経路と性能計測
  の曖昧さを残すため採用しない。
- capabilityを削除し、常にbinaryを暗黙採用する: 契約ずれが初期化ではなく最初のreadで
  発覚するため、必須capabilityを残す方が診断しやすい。
- protocol v2へ直ちに上げる: 今回の変更は現行PoC内の必須化であり、他の契約変更を
  伴わないため、v1のまま capability requirement として扱う。
