# ADR-0031: `findAssets`のfilesystem indexをbuild単位で共有する

- Status: Accepted
- Date: 2026-09-04

## Context

同一build中、Rustのtracked glob処理とDart workerの`find_assets` RPCは、同じpackageの
filesystem asset一覧を繰り返し要求する。毎回rootとcacheを再帰走査すると、glob照合の
前に同じdirectory entryを読み直すことになる。一方、build中はRustが生成物を直接commit
せず、後続phaseにはoverlayで見せるため、base filesystemの変更境界は明確である。

## Decision

- `Workspace`にthread-safeなbuild-scoped cacheを持たせ、package asset一覧と
  `(package, pattern)`ごとの`findAssets`結果を同一build中で共有する。
- cacheはworker threadから共有参照し、worker requestで追加されるoverlay assetは従来どおり
  request処理側で別に追加する。overlayをbase cacheへ混ぜない。
- pending outputの全commitと削除処理が完了した直後、build後snapshotを作る前にcacheをclearする。
- watchの次回buildでは新しい`Workspace`を作るため、filesystem indexをgraphやdiskへ永続化しない。

## Consequences

- 同一build中の重複したdirectory walkと、同じqueryのbase glob照合を減らせる。
- cacheはpackage asset一覧とquery結果を保持するため、build中の短期的なmemory使用量が増える。
- commit boundaryでclearすることで、生成されたcache partと削除されたoutputをbuild後処理が
  見落とさない。途中の外部filesystem mutationは既存のwatch次回buildで再評価する。
- protocol、overlayの優先順位、JSON fallbackの有無は変更しない。

## Alternatives considered

- requestごとにfilesystemを再走査する: 実装は単純だが、反復RPCのI/Oと照合コストを繰り返すため採用しない。
- cacheを複数buildにまたがって保持する: 外部変更・watch・生成物削除との整合性管理が増えるため採用しない。
- overlayを共有asset cacheへ書き込む: phase境界とcommit前の可視性を混ぜ、stale entryを生むため採用しない。
