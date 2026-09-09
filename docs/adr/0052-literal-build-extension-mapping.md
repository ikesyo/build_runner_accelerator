# ADR-0052: literal build extension mapping

## Status

Accepted

## Date

2026-09-05

## Context

任意builderのmanifest subsetは、これまで入力・出力を単純なsuffixとして扱っていた。
しかしbuild_runnerの`build_extensions`は、特定のasset pathを別の固定pathへ写すliteral
mappingも表現できる。これを全てDart fallbackにすると、generic manifest経路の適用範囲が
不必要に狭くなる。一方、capture groupや複雑な正規表現を一度に取り込むと、actionの入力
候補と出力pathの対応をRust側で誤りやすい。

## Decision

- `build_extensions`の入力keyが`^`で始まるliteral pathの場合、先頭の`^`を除いたpathを
  exact inputとしてmanifestへ保存する。
- exact inputの出力は、suffix置換ではなくmanifestに保存したliteral relative pathを同じ
  packageへ付けてAssetIdにする。
- suffix mappingは従来どおり保持し、exact mappingと同じ`BuilderDefinition`・action graph・
  overlay・atomic commitを使う。
- absolute path、親directory、package区切り、wildcard、capture groupを含むmappingはこの
  subsetに入れず、autoではDart fallback、rustではエラーにする。
- 最初の検証は一つのliteral full-path builderに限定し、既存のsuffix builderとの同居、変更
  action集合、byte比較を同じfixtureで確認する。

## Consequences

- path固定型の任意builderを、builder名の組み込みなしでgeneric経路に載せられる。
- `{{}}` capture group、複数input mapping、output patternなどは引き続き明確にfallback境界へ
  留められる。
- manifest v2では`input_match`を省略した既存entryをsuffixとして読めるため、旧manifestとの
  読み取り互換性を保つ。

## Verification

`fixtures/arbitrary_builder_app`に`^lib/special.txt`から
`lib/special.generated.txt`を生成するbuilderを追加した。stock/Rustの初回生成物、special
入力変更時の2 action、既存の削除・rename・failure・watch系caseが通過した。
