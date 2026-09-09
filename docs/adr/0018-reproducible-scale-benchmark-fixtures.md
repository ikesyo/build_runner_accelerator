# ADR-0018: scale benchmarkは追跡済み基準fixtureから都度生成する

- Status: Accepted
- Date: 2026-09-03

## Context

scale benchmarkは10/100/500入力のfixtureを使うが、従来のgeneratorは未追跡の
`json_serializable_10_app`をテンプレートとしていた。そのため、生成物をcleanupした
後やクリーンなcheckoutでは`COUNT=100`のbenchmarkが開始前に失敗する。

一方、benchmarkは各実行でmarkerを書き換え、stockとRustの生成物を比較するため、
リポジトリへ大規模な入力fixtureを常時追加する必要はない。

## Decision

- `fixtures/json_serializable_app`をscale fixture生成の唯一のテンプレートにする。
- `COUNT=N`のbenchmarkでは、対象fixtureがない場合、または`N != 10`の場合に
  `generate_json_serializable_fixture.sh`で`json_serializable_N_app`を都度生成する。
- generatorはtemplateのpackage nameを置換し、入力sourceだけをN件作る。
- correctness/smokeの基準fixtureとscale benchmarkの一時生成fixtureを分離する。

## Consequences

- クリーンなcheckoutでも`COUNT=10/100/500`のbenchmarkを同じコマンドで開始できる。
- 未追跡のseed fixtureへの依存がなくなり、検証失敗の原因切り分けが速くなる。
- benchmark後にscale fixtureのsourceが作業領域へ残るため、CIや利用者向けには一時
  directoryへ出す将来改善余地がある。
- fixture生成とpub getのコスト自体は残るが、benchmark結果の比較条件は安定する。

## Alternatives considered

- 10入力fixtureをリポジトリへ常時追跡する: seedの重複と維持コストが増え、clean
  benchmarkの依存を隠すため採用しない。
- scale fixtureを毎回ゼロから別scriptで組み立てる: pubspec/build.yamlの差分が
  基準fixtureとずれる可能性があるため採用しない。
- generatorのseedを未追跡のまま復元する: cleanupやcheckoutの状態に結果が依存する
  ため採用しない。
