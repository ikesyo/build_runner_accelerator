# ADR-0053: capture group build extension mapping

## Status

Accepted

## Date

2026-09-05

## Context

`build_runner`の`build_extensions`は、単純なsuffixだけでなく
`lib/assets/{{dir}}/{{file}}.txt`のようなcapture groupを入力pathに含められる。
出力側で同じgroupを参照すると、入力の一部を保ったまま別のdirectoryやextensionへ
mappingできる。Mockitoやsource_genのようなbuilderをbuilder名の組み込みなしで扱うには、
この表現をgeneric manifest経路へ渡せることが重要である。

一方、`build_extensions`に複数のinput keyを持つbuilder、post-process builder、capture
groupの不正な参照まで一度に取り込むと、Rust action planningとstockの出力集合がずれる
可能性がある。まずbuild_runnerの通常builderにおけるcapture groupの基本semanticsに限定する。

## Decision

- `build_extensions`が1つのinput keyを持ち、そのkeyに`{{name}}`形式のcapture groupがある
  場合、manifestへ`input_match: capture`として保存する。
- input key先頭の`^`は`input_anchored: true`として保存し、path先頭からmatchする。
  `^`がない場合はbuild_runnerと同じくpathの最初に成立するsuffix matchを使う。
- Rustはcaptureを`.+`相当として扱い、複数groupではinput側のgroup名を一度ずつ保持する。
  各captureはgreedyに試し、後続literalを満たす最長の値を選ぶ。
- outputはinput groupを名前で一度ずつ参照し、captureを展開した文字列をmatch部分の置換先
  としてAssetIdへ変換する。packageはinputから保持する。
- input groupの重複、outputの未知group・重複参照・未参照、absolute/parent/wildcard/
  不正braceを含むmappingはgeneric subsetに入れない。
- `build_extensions`の複数input key、optional builder、post-process builderは引き続き
  autoではDart fallback、rustではエラーとする。
- capture outputもwatchのgenerated-source判定で認識し、Rust自身の生成イベントを再build
  triggerにしない。

## Consequences

- pathのdirectory構造を保つbuilderを、Rust側のbuilder catalogに固有実装を追加せず扱える。
- manifestにはraw patternとanchorだけを保持するため、patternの解釈はRustのaction planningと
  Dart builderの`allowedOutputs`で一致する。
- capture patternのパースは小さな専用実装で行い、generic経路へ正規表現crateを追加しない。
- 複数mappingやbuilder optionsによる動的な`build_extensions`変更は、別のmanifest modelと
  action identity設計が必要になる。

## Verification

`fixtures/arbitrary_builder_app`に、
`^lib/assets/{{dir}}/{{file}}.txt`から
`lib/generated/{{dir}}/{{file}}.dart`を生成するbuilderを追加した。
`scripts/correctness_capture_builder.sh`でstock/Rustのclean、no-op、入力変更、rename、
deleteを比較し、`scripts/watch_smoke_arbitrary_builder.sh`でcapture outputのwatch変更も
比較した。Rust 1.98.1のunit test 31件、Dart analyze、既存任意builderのcorrectnessと
依存fixtureも通過した。
