# ADR-0039: builder定義catalogと共通action planning

- Status: Accepted
- Date: 2026-09-04

## Context

これまでRust frontendは`json_serializable`と
`source_gen|combining_builder`を`main.rs`の固定定数・固定phase・固定output
処理で扱っていた。次に`freezed`、`riverpod_generator`を追加するには、builderごとに
同じ分岐を増やすのではなく、input/output、`build_to`、phase、required input、
`generate_for`、optionsを共通のモデルで扱う必要がある。

一方、任意builderの動的ロードはまだ実装していない。現在のDart workerは静的catalogに
登録したfactoryだけを実行できるため、Rust frontendが未登録builderを推測実行すると、
互換性を保てないままRust経路を選択する危険がある。

## Decision

- Rust側に`BuilderDefinition`を置き、次の実行メタデータをbuilder単位で保持する。
  - builder ID
  - input/output suffix
  - `build_to`
  - phase
  - required input suffix
  - generated outputをinput候補から除外する規則
  - 自動適用する後続builder
- `build.yaml`はcatalogに存在するbuilderだけを認識し、builderごとの
  `generate_for`とoptionsを`ConfiguredBuilder`へ結び付ける。
- 自動適用builderは宣言側の`generate_for`を継承し、phase番号とbuilder IDで
  deterministicに並べる。
- `BuildSpec`とworker requestはoutputsを`Vec`として表現し、現行catalogでは1 outputを
  宣言する。output pathと削除処理はbuilder定義の`build_to`を使う。
- action graphのkey、dirty判定、expected/deleted action、phase実行は既知builderの
  固定matchではなく、生成されたbuilder定義・spec列を使う。
- 対応外のbuilder、YAML構文、glob、optionは従来どおり`--mode auto`ではDart
  fallback、`--mode rust`ではエラーとする。
- IPC protocolのversion、binary capability要件、JSON fallbackなしの方針は変更しない。
  任意builderの動的ロードは別途調査・ADR化する。

## Consequences

- `freezed`や`riverpod_generator`を追加する際、Rustのphase/output/graph処理を新しい
  特別分岐として複製せずに済む。
- 現段階ではcatalogとDart factory登録が必要で、任意builderを自動的に実行できるわけではない。
- `required_input_suffix`と複数outputの表現は共通モデルに入ったが、builder固有のphase
  可視性や複雑なoutput cardinalityは、実builder fixtureで検証してから拡張する。
- 既存の`json_serializable`生成物、incremental、failure、delete、watch semanticsを
  regression gateとして維持する。

## Alternatives considered

- builderごとの`match`を`main.rs`へ追加する: 最初の追加は速いが、builder数に比例して
  graph・output・fallbackの分岐が増え、動的ロードへの移行も難しくなるため採用しない。
- 初回から任意builderを動的ロードする: factory import、依存解決、isolate、外部process、
  multi-outputの境界が未検証で、現行correctness gateを先に満たせないため採用しない。
- stock `build_runner`へ常にfallbackする: 互換性は高いが、Rust frontendのbuilder実行
  経路を検証できず、対応builder拡大の計測対象にならないため採用しない。
