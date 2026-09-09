# ADR-0045: Dart workerのaction別builder実行プロファイル

## Status

Accepted

## Date

2026-09-05

## Context

ADR-0044でworkerのcold startをJIT kernelにより短縮できるようにした。一方、kernel指定後も
Rustの`build_us`にはDart worker内のbuilder factory、Analyzer resolver、builder本体、resolver
依存収集、結果組み立てが含まれる。Rustのaggregate metricsだけでは、対応builderごと・actionごとの
支配要因を切り分けられない。

既存のworker protocolは生成物、reads、resolver reads、glob readsをRustへ返しており、ここへ
計測専用のpayloadを追加すると互換性境界を広げる。計測は、通常実行の出力やstdoutを変更せずに
次の最適化判断に必要な情報だけを取得する必要がある。

## Decision

- `BUILD_RUNNER_ACCELERATOR_METRICS=1`のときだけ、Dart workerが各build actionのstderrへ一行の
  `Dart metrics:` JSONを出力する。
- JSONには`builder`、`input`、`status`、`total_us`、`factory_us`、`resolver_get_us`、
  `resolver_get_calls`、`resolver_first_get_us`、`run_builder_us`、`resolver_reads_us`、
  `result_assembly_us`、outputs/reads/resolver reads/glob readsの件数を含める。
- `Resolvers.get`を薄い計測wrapperで包み、worker lifetime内の最初の成功したresolver取得を
  `resolver_first_get_us`として記録する。resolver reset後もAnalyzer resolver自体の初期化状態を
  再初期化済みとして扱い、既存のlifecycle semanticsを変えない。
- 計測情報をworker protocolのresult payloadへ追加しない。通常時はresolver wrapperも使わず、
  builderのfactory、outputs、reads、diagnostics、commit semanticsを変更しない。
- このprofileは原因の特定に使い、既定の`--jobs`、cache方式、persistent worker化、独立Rust
  frontend化を自動的に決めない。

## Consequences

- kernel使用時に残る`build_us`の内訳をbuilder/action単位で比較できる。
- stderrへ一行ずつ出すため、protocol parserや生成物との互換性を保てる。複数workerで同時に
  出力する場合は行の順序を全体順序として解釈せず、各JSON行を独立したaction記録として扱う。
- metrics有効時はtimer、JSON encode、resolver wrapperの小さな計測コストが加わる。通常時は
  opt-in出力を行わず、resolver wrapperも挿入しない。
- 取得した内訳だけでは最適化の正しさを保証しないため、次の変更でもstock比較、no-op、
  incremental、watch、failureを含む既存gateを維持する。

## Verification

- Dart format/analyzeを実行し、`Dart metrics:`のJSONがstderrに出ることを確認する。
- JSON、Freezed、Riverpodのmatrixを`JOBS=1`・`REPEAT=3`で実行し、byte-identicalとRust no-opを
  維持したままaction別metricsを取得する。
- `VERIFY_LEVEL=full`でJSON/Freezed/Riverpod、watch smoke、Rust unit test、Dart analyzeを通す。

## Alternatives considered

- build result protocolへprofileを追加する: consumerごとの互換性とpayloadサイズを増やすため採用しない。
- Rustのaggregate `build_us`だけを使う: builder/action内の支配要因を分解できないため不十分。
- resolverを常時warm-upする: 測定のためにworker lifecycleと実行順を変更し、最適化判断を
  混ぜてしまうため採用しない。
