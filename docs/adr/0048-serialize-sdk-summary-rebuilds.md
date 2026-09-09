# ADR-0048: SDK summary cache rebuildsをworker間でsingle-flight化する

## Status

Accepted

## Date

2026-09-05

## Context

`build_resolvers` 3.0.4の`defaultSdkSummaryGenerator`は、SDKの宣言と型情報をAnalyzerが
読み込めるsummary bundleへシリアライズし、workspaceの
`.dart_tool/build_resolvers/sdk.sum`へcacheする。summaryが既に有効なら数msで済むが、
SDKやAnalyzerの変更後、または新しいworkspaceでの初回resolver取得では約5秒かかる。

fast_build_runnerはphase内の独立actionに対して複数のDart worker processを起動できる。
summary cacheが空、または古い状態で複数workerが同時にresolverを初めて取得すると、
各processが同じSDK bundleを生成していた。これは生成物の正しさを壊さないが、CPU・I/Oを
重複させる。

## Decision

- `sdk.sum`と`sdk.sum.deps`が現行のDart SDK、Analyzer、`build_resolvers`に対応している場合は、
  既存generatorと同じworkspace-local pathを直接返す。
- cacheが欠落または古い場合だけ、`.dart_tool/build_resolvers/sdk.sum.lock`を
  `FileLock.blockingExclusive`で取得してから既存の`defaultSdkSummaryGenerator`を呼び出す。
- lock取得後は既存generator自身にcacheを再確認させる。先行workerが生成を完了していれば、
  後続workerはsummaryを再生成せず再利用する。
- lock fileは残すがsummary本体の生成・更新は従来どおり`build_resolvers`に委ね、atomic rename、
  dependency metadata、Analyzerのsummary形式をRust側へ複製しない。
- valid cache hitではlock fileを開かず、既存のread-onlyに近い経路とする。lock取得・待機時間は
  opt-in metricsへ記録する。

## Consequences

- 同じworkspaceを使う複数workerのcold buildで、SDK summaryの実生成は一度に制限される。
- cold buildのwall timeは生成そのものが支配するため必ずしも短縮されないが、後続workerの
  duplicate generationによるCPU・I/Oを抑えられる。後続workerが待機した時間とlock後のcache
  check時間を分けて観測できる。
- valid cache hitは従来どおりworkspaceごとのsummaryを使うため、SDK/package versionを無条件に
  別workspaceへ共有しない。workspaceをまたぐ事前生成・global cacheは別途、互換キーを定義して
  検証する。
- stock `build_runner`などlockを認識しないprocessとの同時実行はこのlockの対象外であり、
  既存generatorのatomic更新 semanticsは変更しない。

## Verification

- Dart format/analyzeを実行する。
- `JOBS=2`のFreezed/Riverpod cold benchmarkで、二つのresolver metricsを確認する。
  一方は`resolver_sdk_summary_after_lock_us`が秒単位、もう一方はlock待機後の同値が数msとなり、
  同一summaryの重複生成が起きないことを確認する。
- Freezed/Riverpodのstockとのbyte比較、no-op、incremental、failure、watchを含む既存verificationを
  実行する。

## Alternatives considered

- workerごとに従来どおり生成する: wall timeは同程度でも、cold parallel buildでCPU・I/Oを重複する
  ため採用しない。
- SDK summaryをRustで再実装する: Analyzerのbundle形式とSDK/package versionへの追従責任を
  Rustへ移すため採用しない。
- summaryを全workspaceで無条件に共有する: SDK、Analyzer、`build_resolvers`の互換境界を壊す
  可能性があるため、互換キーを定義するまでは採用しない。
- resolverをeager warm-upする: 通常のworker lifecycleとbuild順序を変更するため採用しない。
