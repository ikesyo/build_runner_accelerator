# ADR-0042: `riverpod_generator` shared-part builderをcatalogへ追加する

- Status: Accepted
- Date: 2026-09-04

## Context

次の対応builderとして`riverpod_generator`を追加する。公式のBuilderは
`SharedPartBuilder`として`.riverpod.g.part`をcacheへ出力し、
`source_gen|combining_builder`が他のshared-partとまとめて`.g.dart`をsourceへ出力する。
したがって、Freezedのsource outputとは異なり、Riverpod本体のactionはcache phaseに属するが、
同じ入力に対するJSON generatorとのpart統合が正しくdirtyになる必要がある。

また、現行workerは`build 4.0.0`、`source_gen 4.2.4`、Analyzer 8系を使っている。
Riverpod Generator 4.xはAnalyzer 13系を要求するため、このPoCではその依存関係を無理に
更新せず、Analyzer 7以上9未満を許容する`riverpod_generator 3.0.3`を使う。

## Decision

- Dart workerの静的builder catalogへ`riverpod_generator.riverpodBuilder`を登録する。
- Rust builder definitionへ次のメタデータを追加する。
  - builder ID: `riverpod_generator`
  - input suffix: `.dart`
  - output suffix: `.riverpod.g.part`
  - `build_to`: `cache`
  - phase: `0`
  - `applies_builder`: `source_gen|combining_builder`
- RiverpodのpartはJSON partと同じphaseで作り、combining actionはphase 1で1回だけ実行する。
  combining builderは`.g.part`をrequired inputとして扱うため、RiverpodとJSONのどちらかの
  partが変更・削除されても、統合sourceを再生成する。
- Riverpod generatorはAnalyzer-backed resolverを使うbuilderとしてworkerへ渡す。resolver readを
  graphへ記録し、resident workerのresolver reset時にはFreezed/JSONと同じ同期境界を使う。
- 現時点でRust frontendが受け付けるRiverpod optionsは、公式の文字列設定である
  `provider_name_prefix`、`provider_family_name_prefix`、`provider_name_suffix`、
  `provider_family_name_suffix`、`provider_name_strip_pattern`に限定する。未知のoptionや
  複雑なYAML形状はDart fallbackへ送る。
- `riverpod_app` fixtureでは、1つの`model.dart`に`@riverpod`、`@JsonSerializable`、
  `@freezed`を置き、`.riverpod.g.part`、`.json_serializable.g.part`、`.g.dart`の
  shared-part/combining経路と`.freezed.dart`のsource outputをstockとRustで比較する。

## Consequences

- Riverpod単体の生成だけでなく、同じsource上のFreezed source outputとJSON partとのphase
  ordering、cache overlay、combining outputのbyte-identical性を検証できる。
- Riverpodの生成物をsourceへ直接commitしないため、Freezedのsource-output専用処理は増えない。
- static catalogは維持されるため、任意のRiverpod builder拡張や未登録builderは従来どおりRust
  frontendの対象外である。動的builder loadingはroadmapのP2に残る。
- 4.xへ上げるにはAnalyzer/build_resolversの更新影響を別途検証する必要がある。

## Verification

Riverpod依存を取得した同一環境で、Rust 29 tests、Dart analyze、既存のJSON/Freezed
correctness、Riverpod correctness、3種類のwatch smokeを実行した。Riverpod correctnessは
no-op、source edit/invalidation、generated output delete、failure rollbackを含む全件がpassし、
Freezed＋Riverpod＋JSONの4 action（Freezed、Riverpod、JSON、combining）のphase関係も
byte-identicalで確認した。

`JOBS=1`のbenchmarkは単回測定で次の値だった。max RSSは環境で取得できなかった。

| Fixture / case | stock | Rust frontend |
| --- | ---: | ---: |
| `riverpod_app` clean | 18.036s | 12.391s |
| `riverpod_app` no-op | 1.692s | 0.022s |
| `riverpod_app` source edit | 4.867s | 5.196s |

clean/no-opはRust frontendが速く、source editはAnalyzerとworker初期化の影響で僅かに遅い。
環境差と単回測定の影響があるため、`--jobs`の既定値は変更しない。

依存取得可能な環境での再現コマンドは次のとおり。

```sh
dart pub get
bash scripts/correctness_riverpod.sh
bash scripts/watch_smoke_riverpod.sh
bash scripts/benchmark_riverpod.sh
```

## Alternatives considered

- Riverpod 4.xへ合わせてAnalyzer一式を更新する: 今回のbuilder追加に対して既存のresolverと
  Freezed/JSONの検証範囲まで変更が広がるため採用しない。
- `.g.dart`をRiverpod builder自身のsource outputにする: JSONなど他のshared-part builderと
  衝突し、公式のcombining semanticsから外れるため採用しない。
- Riverpodを常にDart fallbackへ送る: 互換性は維持できるが、shared-part/cache overlayと
  combining actionをRust frontendで検証できないため採用しない。
