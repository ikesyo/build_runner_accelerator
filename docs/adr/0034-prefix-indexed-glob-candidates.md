# ADR-0034: sorted asset indexでglob候補をliteral prefixに絞る

- Status: Accepted
- Date: 2026-09-04

## Context

linear segment matcher導入後も、tracked globごとにpackageの全assetを候補として走査していた。
500入力fixtureでは約500個の固有globと約1,500個のsource/cache assetの組み合わせが生じ、
matcher自体を軽くしても全候補のfilter処理が残った。`Workspace`のasset一覧はsortedなため、
patternの最初のwildcardより前のliteral prefixを使えば、候補範囲をbinary searchできる。

## Decision

- `package_asset_index`のsorted asset IDsに対して、`package|literal_prefix`のlower boundを
  求め、prefixで連続するassetだけをglob matcherへ渡す。
- literal prefixが空、またはpath-recursiveな`**`を含むpatternでも、prefixは必要条件として
  使い、最終判定は既存のglob semanticsで行う。prefixで一致しないassetは候補から除外する。
- tracked globのsnapshot更新も`find_assets(package, pattern)`を直接利用し、全asset一覧を取得して
  呼び出し側でglobごとに再filterしない。
- package asset/query cache、overlay追加、commit後のcache clear、JSON fallbackなしのstrict
  protocolは維持する。

## Measurement snapshot

2026-09-04、`COUNT=500 JOBS=1 BUILD_RUNNER_ACCELERATOR_METRICS=1`で、build-scoped cacheとlinear
matcherを含む実装から比較した。全ケースで`byte-identical=yes`かつ`no-op=yes`だった。

| ケース | prefix index前のglob stage | prefix index後のglob stage | Rust wall (前 → 後) |
| --- | ---: | ---: | ---: |
| no-op初回 | 660 ms | 49 ms | 0.731 s → 0.124 s |
| 1-file 初回 / build後 | 682 / 712 ms | 52 / 60 ms | 3.204 s → 2.205 s |
| all-file 初回 / build後 | 668 / 666 ms | 51 / 71 ms | 12.716 s → 10.925 s |

値は単回benchmarkの参考値であり、cleanは初回にtracked globがないためbuild後の差が主に現れる。

## Consequences

- literal prefixを持つglobでは、全assetとのcross-productを避け、候補数に比例した照合になる。
- literal prefixがないglobはsorted index全体をfallbackとして走査する。任意globをregexへ変換したり、
  path trieを導入したりする複雑性はまだ追加しない。
- asset indexのsort順とpackage prefixの構造に依存するため、index構築・lower bound・commit後clearを
  一体で変更する必要がある。
- globの一致結果、dependency invalidation、overlayの可視性、生成物は変更しない。

## Alternatives considered

- linear matcherだけを改善する: matcher内のallocationは減るが、全候補filterのコストが残るため採用しない。
- globごとにfilesystemを再走査する: I/Oが増えるため採用しない。
- 全patternを事前にtrie/regexへcompileする: dynamic glob semanticsとlifetime、実装・検証範囲を
  広げるため次段階へ送る。
