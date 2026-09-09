# ADR-0007: native watch と常駐Dart workerを使う

- Status: Accepted
- Date: 2026-09-03

## Context

毎回processを起動するwatchは、Dart SDK、package config、Analyzerの初期化コストを繰り返す。さらに、生成output自身のatomic writeによるfilesystem eventを再ビルドと誤認すると、watchがループする。

## Decision

- `notify`のnative filesystem eventを使い、Rust process内でwatchする。
- 同一watch sessionではWorkerPoolを保持し、package config signatureが変わらない再buildではworker processを再利用する。
- 再build前に`reset`を送り、build-specific analyzer stateだけをworker側でクリアする。
- package configやworkspace signatureが変わった場合はworkerを再起動する。
- generated `.g.dart`の作成・変更は無視し、ユーザーによるgenerated outputの削除だけは再build対象にする。`.dart_tool`はpackage config変更だけを監視する。
- filesystem eventはdebounceして、1回の保存に伴うrename/write burstを1 buildへまとめる。

## Consequences

- watch再実行時のprocess起動と初期化を削減できる。
- 常駐workerの状態リークを避けるため、`reset`の消去範囲を維持する必要がある。
- native eventの種類やOS差を吸収するsmoke testが必要になる。
- workerが異常終了した場合の自動再起動は今後の拡張課題である。

## Alternatives considered

- eventごとにbuild commandを起動する: 実装は単純だが、watchの常駐メリットを失う。
- polling: portabilityは高いが、不要なscanと反応遅延が増える。

