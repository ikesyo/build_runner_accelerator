# ADR-0029: asset readのraw bytesをframe buffer viewでcacheする

- Status: Accepted
- Date: 2026-09-04

## Context

Rustはasset `read`成功応答をBRAB binary frameで返している。Dartのdecoderはmetadataと
raw bytesを含むframe payloadを受け取った後、raw部分を`Uint8List.fromList`で別配列へ
copyしていた。さらに`RemoteAssetReaderWriter.readAsBytes`はその配列をcache用と呼び出し
元返却用に複製していた。

read cacheはresetまでimmutable assetを共有する内部cacheであり、builderへ返す値はcallerの
変更からcacheを守る必要がある。この境界を保ったまま、frame受信直後の全量copyを減らす。

## Decision

- BRAB decoderはraw部分を`Uint8List.sublistView`で参照し、frame payloadをviewのbacking
  bufferとして保持する。
- `RemoteAssetReaderWriter`はそのtyped viewを共有read cacheへ保存し、builderへ返す時に
  `List<int>.from`で防御copyする。
- cacheの優先順位、reset lifecycle、binary capability必須化、missing/errorのJSON応答は
  変更しない。
- builderへborrowed viewを直接返すzero-copy APIは導入しない。

## Consequences

- 新規asset readの受信直後に発生していたraw bytesの中間copyをなくせる。cache hit時の
  builder向け防御copyは残る。
- cache entryがframe payloadのbacking bufferを保持するため、raw bytesに加えてframeの
  metadata領域もcache lifetimeまで保持される。metadataは通常小さく、複雑なshared memory
  lifecycleは導入しない。
- builderが返却値を変更してもcacheは汚染されない。既存のread cache共有とAPIの所有権を
  維持する。

## Alternatives considered

- decoderでraw bytesを常に`fromList`する: 実装は単純だが、binary化後も受信直後の全量copyを
  残すため採用しない。
- cache viewをbuilderへ直接返す: copyをさらに減らせるが、caller mutationによるcache
  破壊を許すため採用しない。
- assetごとにshared memoryやtemp fileへ置く: 大きなassetには余地があるが、cacheの
  lifecycle、cleanup、platform差を広げるため現段階では採用しない。
