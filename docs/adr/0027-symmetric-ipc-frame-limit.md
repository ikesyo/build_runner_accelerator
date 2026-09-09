# ADR-0027: IPC frame上限をRust/Dart双方で対称に適用する

- Status: Accepted
- Date: 2026-09-04

## Context

v1のlength prefixは32-bit unsignedだが、理論上の最大値まで受け入れると、壊れた
metadataやworkerの異常で巨大なpayloadを先にallocateする可能性がある。Rustの受信側
には256 MiBのsafety limitがあった一方、送信側とDart側のreaderには同じ上限が揃って
いなかった。

## Decision

- 完全なlength-prefixed frame（4-byte prefixを除くpayload）の上限を256 MiBとする。
- Rustのreader/writerとDartのreader/writerすべてでこの上限を適用する。
- readerはpayload bufferを確保する前にlengthを検査し、writerはmetadataとraw bytesを
  合算したpayload lengthを検査する。
- 上限超過はprotocol errorとして扱い、v1ではchunkingやJSON fallbackを追加しない。

## Consequences

- Rust/Dartの片側だけが受け入れるサイズ差がなくなり、異常frameによる不要な巨大allocateを
  early rejectできる。
- 256 MiBを超えるbuild resultまたはasset readは現行worker sessionでは成功しない。
  そのサイズ帯を必要とする場合は、chunkingまたは別transportを新しいADRで設計する。
- 上限値は将来のchunking schemaとは独立したsafety boundaryとして扱う。

## Alternatives considered

- 32-bit lengthの最大値まで許可する: protocol上は表現できるが、local IPCでも異常入力へ
  のメモリ上限にならないため採用しない。
- 送信側だけで検査する: 受信側の実装差や将来worker差分でallocate前検査を失うため採用しない。
- 直ちにchunkingを導入する: 通常のPoC生成物には過剰で、metadataと順序復元のschemaを
  広げるため現段階では採用しない。
