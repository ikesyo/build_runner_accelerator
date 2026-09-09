# ADR-0021: 変更のないno-opではaction graphを書き直さない

- Status: Accepted
- Date: 2026-09-04

## Context

no-op buildではdirty actionも削除actionもないため、実行結果としてgraphに新しい情報は
ない。それでも毎回snapshotをstateへ代入してatomic renameしており、watchや短い
incremental buildで不要なfilesystem writeを発生させていた。

## Decision

- `schema_version`、`config_digest`、asset snapshotがすべて同一なら、no-op経路では
  GraphStateを保存しない。
- いずれかが変わる場合は従来どおりmetadataを更新してatomic saveする。
- dirty actionまたは削除actionがある通常buildでは、action更新とpost-build snapshotを
  まとめて従来どおり一度保存する。
- 判定はGraphStateの値比較で行い、mtimeだけでは判断しない。

## Consequences

- no-opのgraph writeとrenameがなくなり、watch連続実行時のI/Oとfilesystem eventを減らせる。
- 初回移行や設定変更などmetadata差分があるno-opでは一度だけ保存される。
- state比較のためのsnapshot scan自体は残るため、scan/digestコストは削減しない。

## Verification snapshot

2026-09-04のsmoke後にRust no-opを実行し、`graph-v3.bin`のinode、mtime、sizeが
実行前後で同一であることを確認した。今回の実装はfilesystem writeを省略するが、
既存graphが壊れている場合の検証・復旧を追加するものではない。

## Alternatives considered

- no-opでは常に保存する: 実装は単純だが、変更のないwatch cycleにもwriteを課すため採用しない。
- mtimeだけで保存要否を決める: 内容差分を見落とすため採用しない。
- graph更新をメモリだけにする: process再起動後のincrementalityを失うため採用しない。
