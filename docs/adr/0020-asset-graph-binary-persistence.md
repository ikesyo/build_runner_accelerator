# ADR-0020: AssetGraphはPoC専用のversioned binary形式で保存する

- Status: Accepted
- Date: 2026-09-04

## Context

Rust frontendのaction graphは`graph-v2.json`へ保存していた。JSONはデバッグしやすい
一方、action数・依存asset数に比例してキー名、空白、構造化文字列を毎回 parse/serialize
する。グラフ構造そのものはまだPoCのdirty判定に十分小さいため、indexed storeへ進む
前段として、現在のGraphStateの構造を保ったまま永続化codecだけを高速化する。

## Decision

- GraphStateのフィールドとdirty判定の意味は変更しない。
- 保存先を`.dart_tool/build_runner_accelerator/graph-v3.bin`へ切り替え、既存のPoC JSON形式は読み取らない。
- codecは新規依存を追加せず、固定幅整数、長さ付きUTF-8文字列、collection countで構成する。
- ファイルheaderに`BRAG` magic、format version、payload lengthを持たせ、未知形式、切断、
  余分なpayload、重複map key、無効なUTF-8/booleanを拒否する。
- saveは従来どおり一時ファイルへのwrite後にrenameする。これはbuild_runner本体の
  AssetGraph形式との互換を意図しない。

## Consequences

- graph fileのI/O bytesとJSON parse/serializeの構造処理を減らせる。
- format切り替え時はgraphが存在しない場合と同じく安全側に再構築する。開発中のPoCでは
  旧graphの移行・fallbackを持たない。
- GraphState全体を毎回decodeする方式は残るため、action graphが極端に大きくなった場合は
  indexed store、lazy lookup、mmapを別途検討する。

## Measurement snapshot

2026-09-04に100入力fixtureを`jobs=1`で1回測定した。binary graphは149,053 bytesで、
直前のcompact JSON実装の176,026 bytesより約15.3%、pretty形式相当の227,543 bytesより
約34.5%小さくなった。Rust cleanは8.280s、全入力変更は5.457sだったが、wall timeは
単回値であり、binary化だけの因果効果は反復benchmarkで確認する。

## Alternatives considered

- bincode/postcard等の新規依存を追加する: codecのためだけにPoCの依存とlockfileを増やすため採用しない。
- build_runner本体のAssetGraph形式を直接読む: Dart側実装との結合が強く、現在のRust frontendの内部graph責務を越えるため採用しない。
- compact JSONを維持する: binaryで省けるfield nameと構造 parseを残すため採用しない。
