# ADR-0041: Freezed builderをsource outputとしてcatalogへ追加する

- Status: Accepted
- Date: 2026-09-04

## Context

次の対応builderとして`freezed`を追加する。Freezedは`.dart`を入力として
`.freezed.dart`をpackage sourceへ出力する`PartBuilder`であり、annotationがない入力では
正常終了しても出力を生成しない。また、Freezedの生成sourceを同じpackage内の
`json_serializable`がresolver経由で参照する構成が一般的である。

Rust frontendは生成物を全action成功後にcommitするため、source outputのphase可視性と、
出力なしの正常actionを明示的に扱わなければstockとの差分やincremental stale outputを
生む。

## Decision

- Rust builder catalogに`freezed`を登録する。
  - input suffix: `.dart`
  - output suffix: `.freezed.dart`
  - `build_to`: `source`
  - phase: `0`（同phaseの`json_serializable`よりbuilder ID順で先に実行）
  - outputはoptional
- Freezed actionのexpected outputはworkerへallowed outputとして渡すが、正常結果が0 output
  でも成功とする。既存actionが出力を持っていた場合、結果に含まれない出力はcommit時に
  削除し、annotation削除でもstale `.freezed.dart`を残さない。
- 同一phaseのbuilder actionからは、そのactionのallowed outputをread/canRead/globの対象外
  とする。これにより前回commit済みの`.freezed.dart`をFreezed自身のresolverが再入力する
  ことを防ぐ。
- source outputを生成したphaseの後続builderへoverlayを公開する。後続phase開始前にworkerへ
  `reset_resolver`を送り、resident workerとasset read cacheは維持したままAnalyzerの
  phase-local graphだけを再同期する。
- optional source outputが削除された場合も削除overlayへ登録する。後続builderのread、
  `canRead`、globから古いfilesystem上の生成物を隠し、全action成功後のcommitで実ファイルを
  削除する。これによりFreezed部分を外した入力からJSON生成を継続する場合もstale outputを
  参照しない。
- `freezed`のfactoryはDart workerの静的catalogへ登録し、resolverを使用するbuilderとして
  実行する。`format`、`copy_with`、`equal`など安全に転送できる既知のbool optionsを受け付け、
  未知または複雑なYAML形状は従来どおりfallbackする。
- `freezed`と`json_serializable`を同じfixtureで併用し、Freezed source output、JSON part、
  combining source outputの順序とbyte-identical結果を検証する。

## Consequences

- Freezed単体、Freezed/JSON併用、no-op、output再生成、入力削除、rename、failure rollback、
  resolver dependency、watch、fallbackをstockと比較できる。Freezed部分の削除とJSON生成を
  同じ入力変更で行うcombined-output-removalも含む。
- annotationのない`.dart`もFreezedのmatching inputとしてworkerへ渡すため、出力なしの
  no-op actionがgraphに記録される。これはbuilderが入力を選別する前のstock phase形状を
  保つためである。
- phase間resolver resetはworker再起動を伴わないが、複数phaseのAnalyzer同期コストが増える。
  clean/no-op/1-file/all-fileを`benchmark_freezed.sh`で計測し、既定worker数やcache方式は
  実測なしに変更しない。
- builder catalogは引き続き静的allowlistであり、任意builderの動的ロードはroadmapの
  P2項目として残る。

## Measurement

2026-09-04、Dart 3.13.3 / Rust 1.91.1、`JOBS=1`、同一ローカルcacheで各benchmarkを
1回実行した。値は`real`秒で、生成物はすべてbyte-identical、Rust no-opも成功した。
この環境ではGNU `time`のmax RSS値は取得できなかった。

| Fixture / case | stock | Rust frontend |
| --- | ---: | ---: |
| `freezed_app` clean | 16.916s | 10.391s |
| `freezed_app` no-op | 1.594s | 0.010s |
| `freezed_app` 1-file | 3.229s | 2.536s |
| `freezed_app` all-file | 3.448s | 3.023s |
| `json_serializable` clean (`COUNT=10`) | 3.054s | 2.353s |
| `json_serializable` 1-file (`COUNT=10`) | 2.781s | 2.159s |
| `json_serializable` all-file (`COUNT=10`) | 2.914s | 2.376s |

Freezed cleanはAnalyzerを含む常駐workerの初期化コストが支配的だが、今回の比較では
Rust frontendが全ケースでstock以下だった。これは単回測定の参考値であり、既定worker数を
変更する根拠にはしない。

## Revalidation

共有セッションの停止後、同じfixture・同じローカルcache・`JOBS=1`で再検証した。
環境はDart 3.13.3 / Rust 1.98.0で、生成物はすべてbyte-identical、Rust no-opも成功した。
GNU `time`のmax RSS値は引き続き取得できなかった。

| Fixture / case | stock | Rust frontend |
| --- | ---: | ---: |
| `freezed_app` clean | 16.928s | 11.262s |
| `freezed_app` no-op | 1.651s | 0.010s |
| `freezed_app` 1-file | 3.094s | 2.586s |
| `freezed_app` all-file | 3.651s | 3.125s |

再検証でもRust frontendは全ケースでstock以下だった。環境差と単回測定の影響があるため、
`--jobs`の既定値は変更しない。

## Alternatives considered

- FreezedとJSONの併用を常にDart fallbackへ送る: 互換性は保てるが、Freezedのsource
  output/phase/overlayをRust frontendで検証できないため採用しない。
- Freezed actionに常にoutputを要求する: annotationなしの正常actionを失敗扱いにし、
  `generate_for: lib/**.dart`の実用的な構成を壊すため採用しない。
- source outputをphase途中でfilesystemへcommitする: resolverから見えるが、後続action失敗時
  に以前の出力を戻すtransactionが複雑になり、既存の全成功後atomic commitを弱めるため採用しない。
- phaseごとにworkerを再起動する: resolver状態は確実に初期化できるが、常駐workerとasset
  read cacheの性能特性を失うため採用しない。
