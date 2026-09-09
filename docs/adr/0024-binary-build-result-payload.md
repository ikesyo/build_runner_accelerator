# ADR-0024: build resultのoutputsをraw bytes frameで返す

- Status: Accepted
- Date: 2026-09-04

## Context

現行のbuild resultは、`outputs[].bytes`をJSONの数値配列としてRustへ返している。
生成物の各byteがJSON tokenになるため、serialize、parse、frame sizeのいずれにも
不要なコストがある。一方、`reads`、`resolver_reads`、`glob_reads`、diagnosticsは
incremental判定に必要なmetadataであり、単純にinputs/outputsの名前だけを返すことは
正しくない。

## Decision

- 成功した`build_result`と`build_batch_result`は、`FBRR` magic、metadata length、JSON
  metadata、連結したraw output bytesからなる1つのbinary frameで返す。
- metadataの各outputは`asset`と`length`だけを持ち、raw bytesはsingle resultでは
  outputs順、batchではresults内のoutputsをdepth-first順に連結する。
- `reads`、`resolver_reads`、`glob_reads`、diagnostics、status、errorなどのmetadataは
  JSONのまま保持する。
- workerは`build-result-binary-v1` capabilityを広告し、Rustは初期化時に必須化する。
  JSON形式のbuild resultへのfallbackは実装しない。
- エラー応答は従来どおりJSONとする。現行の256 MiB frame safety limitを超える結果の
  chunkingは別の判断として扱う。

## Measurement snapshot

100入力、`jobs=1`のbenchmarkで、cleanと全入力変更のbuild result frameは2個合計
194,278 bytesだった。同じ復元済み結果を旧JSON bytes配列で表した想定frameは
417,128 bytesで、53.4%小さくなった。1-file変更ではbinary 3,226 bytes、JSON換算
5,405 bytesで、40.3%小さくなった。いずれも`build_result_bytes`と
`build_result_json_bytes`を同じRust metrics runで比較した値であり、frameのlength
prefixを含む。生成物はbyte-identicalで、benchmarkのno-op gateも通過した。

このJSON換算値は比較のためにRustで再serializeした値であり、metrics有効時だけ計算
する。通常実行のprotocolには追加のJSON serializeは発生しない。

## Consequences

- byte配列のJSON token化をなくし、Rust側はraw sliceから`Vec<u8>`を復元できる。
- batchでもoutputごとのframeは増えず、既存のworkerの中間asset RPCと共存できる。
- 現在はRust側でoutput bytesを復元するためのcopyが発生する。zero-copyやchunkingは
  生成物サイズが大きくなった時点で再評価する。
- protocol変更は開発中のstrict capability境界で扱い、古いworkerとの互換性を維持しない。

## Alternatives considered

- JSON bytes配列を維持する: 実装は簡単だが、大きな生成物ほどserialize/parseのコストが
  増えるため採用しない。
- outputごとにbinary frameを送る: frame数と同期点が増え、batchのmetadataとの対応も
  複雑になるため採用しない。
- MessagePack/CBOR/Protobufで全messageを置き換える: metadata全体のschema・decoder・
  依存を増やす。今回の支配的なbytes配列だけを先に置き換える方がPoCの検証範囲に合う。
- shared memoryや一時fileを使う: 大きな結果には有効になり得るが、所有権、cleanup、
  atomic commitの検証を広げるため現段階では採用しない。
