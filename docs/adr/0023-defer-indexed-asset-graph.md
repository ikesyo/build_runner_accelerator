# ADR-0023: indexed/lazy AssetGraphへの移行を現段階では見送る

- Status: Accepted
- Date: 2026-09-04

## Context

graph-v3の全体decodeと全体saveが、100入力fixtureのbuild wall timeに占める割合を
確認してから、indexed/lazy store、SQLite、mmapなどの複雑な永続化方式を導入する。
新規PoCの開発中は旧graph形式との互換性や移行fallbackを要求しないため、判断を
正しさと実装コストのトレードオフに集中できる。

## Decision

- 現段階では、`GraphState`を全体decodeする現在のversioned binary codecを維持する。
- indexed/lazy store、SQLite、mmap、およびgraphの部分読み込みは、今回のPoCには追加しない。
- まずworker IPC、filesystem scan、dirty判定、schedulerの最適化を優先する。
- より大きいfixtureまたは代表的な反復benchmarkで、graph persistenceがbuild wall timeの
  おおむね5%を継続的に超える、またはgraph sizeとstage latencyが明確に増大した場合に、
  次のADRでindexed/lazy化を再評価する。この割合は契約上のSLOではなく、調査開始の目安とする。
- 旧JSON graphの読み込み、移行、互換fallbackは実装しない。開発中の形式変更は新しい
  versioned binary codecとして扱う。

## Measurement snapshot

100入力、`jobs=1`のstage metricsではgraph fileは147,895 bytesだった。Rust frontendの
graph stageは、no-opでload 1,341 µs / save 0 µs、1-fileで1,125 / 994 µs、全入力変更
（200 actions）で1,259 / 1,615 µsだった。一方、対応するfrontend wall timeはそれぞれ
0.407 s、2.510 s、5.545 sだった。cleanの初回生成はload 5 µs / save 1,063 µs、wall
8.506 sだった。全ケースで生成物のbyte-identicalとRust no-opを確認した。

この測定では、graph stageはbuild全体より十分小さく、永続化方式を複雑化しても現在の
検証対象のwall timeを大きく短縮できる根拠がない。

## Consequences

- graph persistenceの実装と検証面を小さく保ち、workerやincremental判定の改善に集中できる。
- dirty buildではgraph全体のdecodeとsaveが残るため、graphが大きくなるとこの判断は見直しが
  必要になる。
- graph fileはPoC専用形式のままで、形式変更時に旧データを自動移行する必要はない。
- indexed/lazy化の検討時には、今回と同じclean/no-op/1-file/all-fileの各stage metricsを
  再計測し、wall timeだけでなく正しさと実装コストも比較する。

## Alternatives considered

- 今すぐindexed/lazy storeにする: 現測定ではgraph stageが支配的でなく、複雑性に対する
  効果を説明できないため採用しない。
- SQLiteまたはmmapを導入する: PoCの依存、更新原子性、障害時復旧の検証範囲を広げるため、
  同じく現段階では採用しない。
- graph persistenceを最適化しないまま計測もしない: 大規模化した際の再評価基準を失うため、
  ADR-0022のopt-in stage metricsは維持する。
