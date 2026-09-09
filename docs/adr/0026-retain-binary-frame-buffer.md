# ADR-0026: binary frameのraw bufferをdecode完了まで保持する

- Status: Accepted
- Date: 2026-09-04

## Context

`read_message_with_size`は受信payloadを`Vec<u8>`へ読み込んだ後、binary
envelopeのraw部分を別の`Vec<u8>`へ切り出していた。BRARのdecodeでは、そのraw
bytesをさらに各`BuildOutput`のowned `Vec<u8>`へコピーするため、frame全体に相当する
copyが一つ余分に発生する。

一方、build resultはdecode後にworker frameが破棄されてもoverlayとgraph更新で利用する
ため、最終的な各outputのowned copy自体は必要である。

## Decision

- `BinaryFrame`はraw部分だけを独立した`Vec`に切り出さず、受信payload全体とraw開始
  offsetをdecode完了まで所有する。
- `raw_bytes()`でraw部分をviewし、build result decodeは各outputへ必要な一回だけ
  `Vec<u8>`を作る。
- JSON frameのdecode経路と、BRARのmetadata schema・output順序・strict capability境界は
  変更しない。
- outputをframe bufferへborrowさせるzero-copy API、shared memory、mmapは今回導入しない。

## Consequences

- BRAR受信時のraw payload全体の中間copyをなくし、output復元のcopy回数を二重から一回に
  減らせる。
- decode中はpayload全体と復元済みoutputが同時に存在する。decode完了後にframe bufferが
  破棄されるため、通常の`BuildResult`の所有権モデルは変わらない。
- raw bytesをborrowしたまま保持するzero-copyにはならないため、巨大生成物でのpeak RSSは
  なお再評価が必要である。

## Alternatives considered

- raw部分を従来どおり別`Vec`へcopyする: 実装は単純だが、BRARのpayloadサイズに比例する
  不要なcopyと一時メモリを残すため採用しない。
- `BuildResult`をframe bufferへのlifetime付きborrowにする: overlay・graph・worker poolへ
  所有権を渡す設計を複雑化し、今回のPoCの責務境界を広げるため採用しない。
- shared memoryやmmapへ移行する: copy削減の余地はあるが、FD/lifecycle/cleanupと
  platform差の検証が必要になるため、ADR-0025のv1 transport判断と合わせて見送る。
