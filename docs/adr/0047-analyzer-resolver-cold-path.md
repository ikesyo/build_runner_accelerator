# ADR-0047: Freezed/Riverpodのcold Analyzer resolver初期化計測

## Status

Accepted

## Date

2026-09-05

## Context

ADR-0045でDart workerのaction別metricsを追加し、`resolver_first_get_us`で最初のresolver取得を
確認できるようにした。しかし、この値には`AnalyzerResolvers`のlazy initializationに含まれる
package config、SDK summary、Analyzer driver生成が混在しているため、Freezed/Riverpodのcold build
で次に最適化すべき境界を判断できなかった。

Rust 1.98.1、Dart 3.13.3、`build_resolvers` 3.0.4、`JOBS=1`で
`scripts/benchmark_resolver_cold_path.sh`を実行した一回の参考値は次のとおりだった。

| fixture | package config | resolver constructor | SDK summary | first resolver get | SDK summary後 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Freezed | 46 ms | 12 ms | 4.607 s | 4.620 s | 13 ms |
| Riverpod併用fixture | 43 ms | 12 ms | 4.789 s | 4.802 s | 13 ms |

Riverpod併用fixtureの最初のresolver-backed actionはFreezedなので、両者の初期化経路を同じ
条件で確認する測定であり、Riverpod generator単独の初期化時間を意味しない。SDK summary後の
値はfirst resolver getからSDK summary時間を差し引いた診断値で、Analyzer driver生成を含む。

## Decision

- `BUILD_RUNNER_ACCELERATOR_METRICS=1`のときだけ、worker起動時のpackage config読み込みとresolver
  constructorを計測する。
- `AnalyzerResolvers.custom`へ渡すSDK summary generatorを計測時だけ薄くwrapし、SDK summary
  経過時間を記録する。通常時は既定generatorをそのまま使う。
- 最初に成功したresolver取得の全体時間を計測し、`Dart resolver metrics:`として一worker一行を
  stderrへ出力する。出力にはbuilder/inputと、package config、constructor、SDK summary、first
  get、SDK summary後の時間を含める。
- 既存のaction単位`Dart metrics:`にも同じstage値を含め、action profileとcold pathを照合できる
  ようにする。計測情報はworker protocolのpayloadへ追加しない。
- resolverをeager warm-upせず、`PackageConfig`の渡し方、resolver reset、worker lifecycle、
  Analyzerの実行順序を変更しない。SDK summaryの共有・事前生成はこの計測結果を基にした次の
  調査項目とする。

## Consequences

- Freezed/Riverpodのcold resolver取得はAnalyzer driver生成よりSDK summary経路が支配的である
  ことを、再現可能なfixtureで確認できる。
- metricsを無効にした通常実行では、resolver generatorのwrapとstderr出力を挿入しない。
- metrics有効時はtimer、JSON encode、SDK summary wrapperの小さな計測コストが加わる。
- SDK summaryはSDK/package versionとworkspaceの依存関係を持つため、cacheを別workspaceへ
  無条件に共有してはならない。改善時もstock比較と既存のfailure/watch gateを維持する。

## Verification

- Dart format/analyzeを実行した。
- `scripts/benchmark_resolver_cold_path.sh`でFreezed/Riverpodのclean buildを実行し、生成物の
  byte-identical、Rust no-op、`Dart resolver metrics:`出力を確認した。
- JSON、Freezed、Riverpodのcorrectness・watch smoke・既存benchmarkを含むfull verificationを
  実行する。

## Alternatives considered

- resolverを常時warm-upする: 実行順序とlifecycleを変え、測定と最適化を混ぜるため採用しない。
- `build_resolvers`をforkしてAnalyzer内部を直接計測する: 依存の追従負担と互換性リスクが大きく、
  まず公開されたgenerator境界で十分な切り分けを行う。
- SDK summaryをRustで再実装する: Analyzerのsummary形式・SDK/package versionとの互換境界を
  Rustへ移すため、計測結果に基づく別の設計判断なしには採用しない。
- persistent worker sessionだけで対応する: 後続buildには効くが、process初回のSDK summary
  支配要因を解消しないため、cold path計測の代替にはならない。
