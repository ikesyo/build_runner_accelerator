# ADR-0032: 非再帰globのsegment照合をallocation-freeな線形matcherにする

- Status: Accepted
- Date: 2026-09-04

## Context

従来のsegment matcherは、`*`と`?`の各照合でpattern/valueを`Vec<char>`へ変換し、
DP tableを確保していた。100入力fixtureでは、actionごとに異なるtracked globが約100個あり、
約300 assetとの照合がscan後とbuild後に発生するため、filesystem scanそのものよりglob
照合が支配的になっていた。

## Decision

- segmentにpath-recursiveな`**`が含まれない場合、path segmentをiteratorで順に照合し、
  `Vec`を作らない。
- `segment_matches`は、wildcardなしなら直接比較し、wildcardありではUnicode scalarの
  境界を保つ線形の`*` backtracking matcherを使う。`?`は従来どおり1文字に一致する。
- segment全体が`**`になるrecursive path globは既存のrecursive処理を維持する。
- representativeな`*`、`?`、Unicode、recursive globのunit testを追加し、wire protocolや
  graphのsnapshot semanticsは変更しない。

## Measurement snapshot

2026-09-04、`COUNT=100 JOBS=1 FAST_BUILD_RUNNER_METRICS=1`で、直前のbuild-scoped
asset cacheを含む実装と比較した。単回測定のため、wall timeは参考値とする。

| ケース | 旧glob stage | 新glob stage | Rust wall (旧 → 新) |
| --- | ---: | ---: | ---: |
| no-op初回処理 | 316 ms | 30 ms | 0.353 s → 0.068 s |
| 1-file 初回 / build後 | 323 / 326 ms | 29 / 32 ms | 2.558 s → 1.974 s |
| all-file 初回 / build後 | 331 / 316 ms | 33 / 33 ms | 5.781 s → 3.973 s |

cleanは初回にtracked globがないため、初回glob stageは両方ともほぼ0で、build後に差が現れる。
全ケースで`byte-identical=yes`かつ`no-op=yes`を維持した。

## Consequences

- tracked globの照合で毎回発生していた小さな配列・DP tableの確保をなくし、stage latencyを
  およそ10分の1へ下げられる。
- `**` recursive path globはまだvector/recursive処理を使う。複雑なglobを次に最適化する場合は、
  semanticsを固定する別benchmarkとADRが必要になる。
- linear matcherは入力長に対してbacktrackingするが、segment内の`*` semanticsを保ちつつ、
  現行fixtureの短いpatternではDPより低いallocation overheadになる。

## Alternatives considered

- 既存DP matcherを維持する: semanticsは明快だが、反復照合のallocationコストが測定上支配的なため採用しない。
- glob patternをbuild開始時に完全compileする: さらなる余地はあるが、pattern parserとlifetimeを広げるため次段階に送る。
- regexへ変換する: 依存、compileコスト、`**`のpath semantics検証を増やすため採用しない。
