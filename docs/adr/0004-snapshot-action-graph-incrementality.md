# ADR-0004: snapshot と action graph でincremental判定する

- Status: Accepted
- Date: 2026-09-03

## Context

入力ファイルだけでdirty判定すると、Builderが読んだ依存asset、生成物の削除、生成物の外部変更、前回と異なる設定を見落とす。`build_runner`互換の最小条件として、前回の実行事実を再利用する必要がある。

## Decision

- root packageと追跡済み依存・glob assetについて、存在有無、size、content digestをsnapshotに記録する。
- action keyはbuilderとinput assetから作り、actionごとにreads、resolver reads、glob reads、outputs、output digest、statusを保存する。
- 前回stateのschema versionとbuild config digestが一致する場合だけ、snapshotと依存記録を用いてdirty判定する。
- 前回存在しなかったassetも`exists=false`として追跡し、後から追加されたときに無効化できるようにする。
- graph stateは`.dart_tool/fast_build_runner/graph-v2.json`へ保存する。

## Consequences

- no-op buildではBuilder processを起動せず、Rustだけで終了できる。
- graph stateの読み書きとdigest計算が増えるため、小規模fixtureでは常に高速になるとは限らない。
- schema変更時は安全側に全対象actionをdirtyにできる。

## Alternatives considered

- mtimeだけを保存する: timestamp精度、checkout、外部変更で誤判定しやすい。
- action単位ではなく全体digestだけを保存する: 1ファイル変更時の影響範囲を縮小できない。

