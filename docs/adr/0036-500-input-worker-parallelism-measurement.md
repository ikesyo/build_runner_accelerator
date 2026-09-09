# ADR-0036: 500入力fixtureではjobs=2を比較対象にする

- Status: Accepted
- Date: 2026-09-04

## Context

ADR-0014は100入力fixtureで`--jobs 1/2/4`を比較し、既定値を1に保った。直近のglob
候補範囲インデックス化後はfilesystem stageが短くなったため、500入力でも同じ判断が
成立するかを再確認する。workerはphaseごとにaction数へ合わせて遅延起動されるため、
`jobs=2`を指定してもno-opや1-action phaseで必ず2 processになるわけではない。

## Decision

- 500入力fixtureの全入力変更では`--jobs 2`を有力な性能比較対象として残す。
- CLIの`--jobs`既定値は1から変更しない。workerごとのAnalyzer state、IPC、read responseの
  重複を、利用者の全buildへ自動的に課す根拠はまだ不足している。
- correctness gateは引き続き`jobs=1`相当の直列条件で実行し、parallelismはbenchmarkで
  byte identityとresource metricsを併記して評価する。

## Measurement snapshot

2026-09-04、同一500入力fixtureでprefix-indexed glob実装を使い、各ケース1回測定した。
単位は秒である。

| case | Rust `jobs=1` | Rust `jobs=2` |
| --- | ---: | ---: |
| no-op | 0.124 | 0.126 |
| 1-file | 2.205 | 1.978 |
| all-file | 10.925 | 8.030 |

全ケースで生成物はbyte-identical、Rust no-op gateはpassした。`jobs=2`のall-file runでは
worker 2個、IPC frame 4,554、asset request 3,552、read request 1,526、read response
bytes 780,628だった。`jobs=1`よりwall timeは短いが、worker間のcache共有がないため、
CPU・IPC・response bytesとのトレードオフを伴う。

同じrunのgraphは731,453 bytesで、load約5.9ms、save約4.8msだった。graph persistenceは
このfixtureのall-file wall timeの支配要因ではなく、indexed/lazy AssetGraphはADR-0023
どおり保留する。

## Consequences

- 大規模なclean/all-file benchmarkでは、`JOBS=2`を明示してwall time短縮を確認できる。
- no-opではworkerを起動しない既存schedulerの性質を維持できる。
- `jobs=2`を既定にしないため、resource使用量を性能値だけで隠さない。
- 1回の測定値は環境依存であり、別fixture・複数回測定で再確認が必要である。

## Alternatives considered

- `jobs=2`を既定にする: 500入力のall-fileには有利だが、既定のresource costとcache重複を
  まだ正当化できないため採用しない。
- `jobs=4`を既定または推奨にする: 100入力でjobs=2を下回った実績があり、500入力でも
  未測定のまま推奨する理由がない。
- 並列correctness gateを再開する: ADR-0012で確認した再現性リスクを持ち込むため採用しない。
