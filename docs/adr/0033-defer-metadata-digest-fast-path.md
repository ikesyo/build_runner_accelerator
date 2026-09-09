# ADR-0033: metadata fast pathを現段階では見送る

- Status: Accepted
- Date: 2026-09-04

## Context

Phase 1の候補として、root snapshotの各fileについてmtime/sizeを保存し、変更がない場合に
content readとdigestを省くmetadata fast pathを検討した。ただし、mtimeの精度や外部変更、
atomic save、filesystem差をsnapshot形式へ持ち込むと、false negativeによるdirty判定漏れを
許すリスクがある。

## Measurement snapshot

2026-09-04、`COUNT=500 JOBS=1 BUILD_RUNNER_ACCELERATOR_METRICS=1`で計測した。root scanは
1,003 assets / 475,158 bytesに対して、clean/no-op/1-file/allでそれぞれ約11.7/12.2/10.5/12.5ms
だった。dirty判定は約7.9/14.0/14.5/10.9msだった。

同じrunでは、prefix index導入後のtracked glob stageが約49–71ms、graph load/saveが約0–13ms
であり、root scanだけをmetadata fast pathにしても現在の支配コストは解消しない。

## Decision

- `AssetSnapshot`へmtime、mtime precision、inode、filesystem fingerprintなどを追加しない。
- root fileは現行どおりcontentをreadしてdigestし、sizeもcontentから確定する。
- graph schema、snapshot semantics、watchの変更検知を変更しない。
- 実filesystemまたはremote filesystemでroot scanが継続的に支配的になる場合は、同じ
  correctness caseとcontent mutation testを再実行した上で、新しいADRで再評価する。

## Consequences

- 同じsizeやtimestampに見えるcontent変更をmetadataのfalse negativeで見落とさない。
- 現在のfixtureでは約10ms規模のread/digestコストを残すが、主因であるglob/worker処理を
  先に最適化できる。
- graph形式を変更せず、mtime precisionやplatform-specific stat semanticsの検証範囲を増やさない。

## Alternatives considered

- mtime+sizeが同じならdigestを再利用する: 一般的な変更では速いが、timestamp精度・clock・atomic
  replaceの差で正しさを落とす可能性があり、現段階では採用しない。
- stat metadataをgraphへ永続化する: graph schemaとmigration/invalidating条件を増やす割に、
  現在の測定では効果が小さいため採用しない。
- content digestをやめてmtimeだけにする: mutation detectionの保証を弱めるため採用しない。
