# ADR-0028: build resultのraw output chunksを連結せず送信する

- Status: Accepted
- Date: 2026-09-04

## Context

FBRRはmetadataの後ろにoutput bytesを順番に置く必要がある。従来のDart workerは
`BytesBuilder(copy: false)`へ全outputを追加し、`takeBytes()`で1本の`Uint8List`にして
からframeへ渡していた。single resultでoutputが1個ならcopyは起きないが、batch result
では複数chunkを連結するため、全raw bytesに比例した一時copyが発生する。

また、`RemoteAssetReaderWriter.writeAsBytes`が通常の`List<int>`として保持した値を
serializerが再度`Uint8List`へ変換していたため、出力生成から送信までのcopy境界も明確で
なかった。

## Decision

- `writeAsBytes`のAPI境界で一度だけ防御copyし、worker内のbuild outputを`Uint8List`として
  保持する。
- FBRR serializerはoutput metadataを作りながらraw `Uint8List`のchunk一覧を収集する。
- metadataと全chunkの合計長を事前計算した後、length prefix、magic、metadata、raw chunksを
  wire上の順序どおり同じ1 frameとして`IOSink`へ追加する。
- wire format、output順序、frame数、strict capability境界は変更しない。上限超過時は
  従来どおり送信前にprotocol errorとし、chunked protocolは導入しない。

## Consequences

- batch resultを送るための全raw bytesの連結copyをなくし、output bytesはAPI境界の防御copy
  とOS/IO実装側のbufferingだけで送れる。
- `IOSink`内部のbufferingやkernelへのcopyまでをゼロにするものではない。巨大payloadの
  peak RSSと実wall timeは実builder benchmarkで再評価する。
- metadataを先に確定する必要があるため、送信開始前にoutput descriptorとraw chunkの一覧を
  worker memory上に保持する。これは既存のbuild result保持と同じaction単位の範囲である。

## Alternatives considered

- 連結済み`Uint8List`を作ってから送る: 実装は単純だが、batchのraw bytes全体を追加copy
  するため採用しない。
- outputごとにframeを送る: frame数とmetadata対応を増やし、ADR-0024のsingle-frame判断を
  崩すため採用しない。
- builderが所有するbytesを防御copyなしで保持する: callerの再利用・変更で結果が変わる
  可能性があり、`writeAsBytes`の安全な所有権境界を失うため採用しない。
