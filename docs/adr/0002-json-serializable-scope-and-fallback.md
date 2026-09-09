# ADR-0002: `json_serializable` の限定形状から開始し、未対応設定はfallbackする

- Status: Accepted
- Date: 2026-09-03

## Context

`build_runner` は任意のbuilder、target、`generate_for`、option、phase構成を扱う。PoCがbuild.yamlを部分的に解釈して誤った入力集合や出力集合を選ぶと、成功して見える不正な生成物を作る危険がある。

## Decision

- 最初のRust frontendの対象を、`json_serializable` と `source_gen|combining_builder` の2 phaseに限定する。
- `build.yaml` はroot packageの`$default` targetにある限定的な`json_serializable.generate_for`と既知optionだけを解釈する。
- `--mode auto`では、未対応の構文・builder・glob・option・worker packageを検出したら既存Dart `build_runner`へfallbackする。
- `--mode rust`では同じ条件をエラーにして、未対応を黙って選択しない。
- `--mode dart`は常に既存Dart実装を使う。

## Consequences

- PoCの対応範囲は狭いが、未対応ケースでの誤実行を避けられる。
- fallbackとのbyte比較を基準に、対象範囲を段階的に広げられる。
- auto modeでは、Rust frontendとDart fallbackの結果・性能を別々に測定する必要がある。

## Alternatives considered

- YAMLを汎用的に解釈して全builderを推測する: builder semanticsを誤る可能性が高いため採用しない。
- 未対応設定もRustで実行する: 互換性を損なうため採用しない。

