# Architecture Decision Records

このディレクトリは、Rust frontend PoC の設計・互換性・性能に関する判断を記録する。

## 運用方針

- 1つのADRには、後から見直す可能性がある1つの判断を記録する。
- 番号は採番順に増やし、過去の判断は書き換えず、必要なら新しいADRで置き換える。
- `Status`、`Date`、`Context`、`Decision`、`Consequences`、`Alternatives considered` を基本構成とする。
- IPC、graph、依存無効化、commit、watch、scheduler、性能計測、互換性境界など、今後の設計や最適化に影響する判断は、実装変更と同じ変更単位でADRを追加する。
- 単なる typo 修正や機械的なリファクタリングは、判断を伴わない限りADRの対象外とする。
- ベンチマーク値は環境依存なので、数値だけで判断を固定せず、測定条件とトレードオフをADRに残す。

## 一覧

| ADR | 判断 |
| --- | --- |
| [0001](0001-rust-frontend-dart-worker-boundary.md) | Rust frontend と Dart worker の責務境界 |
| [0002](0002-json-serializable-scope-and-fallback.md) | `json_serializable` から始め、未対応形状は保守的にfallback |
| [0003](0003-length-prefixed-json-ipc.md) | length-prefixed JSON IPC と action batch |
| [0004](0004-snapshot-action-graph-incrementality.md) | snapshot と action graph による差分実行 |
| [0005](0005-observed-dependency-tracking.md) | 実読みに加え resolver/glob/missing dependency を追跡 |
| [0006](0006-overlay-atomic-commit.md) | overlay と全成功後の atomic commit |
| [0007](0007-native-watch-worker-lifecycle.md) | native watch と常駐 worker lifecycle |
| [0008](0008-action-count-aware-worker-scheduler.md) | action 数に応じた遅延起動 scheduler |
| [0009](0009-opt-in-runtime-metrics.md) | stderr-only の opt-in runtime metrics |
| [0010](0010-verification-tiers-and-parallel-cases.md) | 検証tierと独立correctness caseの並列実行案（0012で置換） |
| [0011](0011-reset-scoped-asset-read-cache.md) | reset区間に限定したworker内asset read cache |
| [0012](0012-serial-correctness-gate-after-parallel-trial.md) | correctness gateを逐次実行へ戻す |
| [0013](0013-optional-watch-smoke-in-quick-verification.md) | quickのwatch smokeをopt-inにする |
| [0014](0014-benchmark-guided-worker-parallelism.md) | benchmarkに基づくworker parallelismの既定値 |
| [0015](0015-reset-scoped-positive-can-read-cache.md) | reset区間に限定したpositive `canRead` cache |
| [0016](0016-isolated-correctness-fixture-workspace.md) | correctness fixtureを同期対象外の一時workspaceで実行 |
| [0017](0017-binary-asset-read-response.md) | asset `read`成功応答を単一バイナリフレームで運ぶ |
| [0018](0018-reproducible-scale-benchmark-fixtures.md) | scale benchmarkを追跡済み基準fixtureから都度生成 |
| [0019](0019-require-binary-asset-read-capability.md) | 新規PoCではbinary asset `read`を必須にする |
| [0020](0020-asset-graph-binary-persistence.md) | AssetGraphをPoC専用のversioned binaryで保存 |
| [0021](0021-skip-unchanged-graph-writes.md) | 変更のないno-opではgraphを書き直さない |
| [0022](0022-graph-persistence-stage-metrics.md) | graph persistenceのstage metricsをopt-inで出力 |
| [0023](0023-defer-indexed-asset-graph.md) | indexed/lazy AssetGraphへの移行を現段階では見送る |
| [0024](0024-binary-build-result-payload.md) | build resultのoutputsをraw bytes frameで返す |
| [0025](0025-stdio-pipe-transport.md) | 子workerとのtransportはstdin/stdout pipeを維持 |
| [0026](0026-retain-binary-frame-buffer.md) | binary frameのraw bufferをdecode完了まで保持し二重copyを避ける |
| [0027](0027-symmetric-ipc-frame-limit.md) | Rust/Dart双方で256 MiB frame上限を適用 |
| [0028](0028-stream-build-result-output-chunks.md) | Dart workerのbuild result raw chunksを連結せず送信 |
| [0029](0029-zero-copy-asset-read-view.md) | Dart側asset read raw bytesをframe buffer viewでcacheする |
| [0030](0030-filesystem-stage-metrics-before-scan-optimization.md) | scan最適化前にfilesystem stage metricsを追加 |
| [0031](0031-build-scoped-find-assets-cache.md) | `findAssets`のfilesystem index/queryをbuild単位で共有 |
| [0032](0032-linear-segment-glob-matcher.md) | 非再帰globのsegment照合をallocation-freeな線形matcherにする |
| [0033](0033-defer-metadata-digest-fast-path.md) | metadata fast pathを現段階では見送る |
| [0034](0034-prefix-indexed-glob-candidates.md) | sorted asset indexでglob候補をliteral prefixに絞る |
| [0035](0035-reuse-prebuilt-rust-binary-in-verification.md) | 検証中は事前ビルド済みRust frontendを再利用 |
| [0036](0036-500-input-worker-parallelism-measurement.md) | 500入力では`jobs=2`を性能比較対象にする |
| [0037](0037-build-scoped-shared-asset-read-cache.md) | worker間でbuild-scoped asset read bytesを共有 |
| [0038](0038-parallel-worker-build-batches.md) | 複数workerでもphase内requestをbatch化 |
| [0039](0039-builder-definition-catalog-and-action-planning.md) | builder定義catalogと共通action planning |
| [0040](0040-rust-frontend-module-boundaries.md) | Rust frontendの責務別module分割 |
| [0041](0041-freezed-builder-support.md) | Freezed builderのsource output・optional output・phase resolver境界 |
| [0042](0042-riverpod-generator-support.md) | Riverpod shared-part builderのcache output・static catalog登録 |
| [0043](0043-builder-performance-matrix-and-stage-metrics.md) | builder横断性能マトリクスとworker stage metrics |
| [0044](0044-precompiled-worker-kernel.md) | Dart workerの任意指定JIT kernelによるcold start短縮 |
| [0045](0045-dart-worker-action-profile.md) | Dart workerのaction別builder実行プロファイル |
| [0047](0047-analyzer-resolver-cold-path.md) | Freezed/Riverpodのcold Analyzer resolver初期化を段階計測 |
| [0048](0048-serialize-sdk-summary-rebuilds.md) | SDK summary cache rebuildsをworker間でsingle-flight化 |
| [0049](0049-dynamic-builder-manifest.md) | build.yamlからworkspace固有のdynamic builder workerを生成 |

| [0050](0050-generic-manifest-first-builder-boundary.md) | manifest-firstの汎用builder境界と任意fast pathの分離 |
| [0051](0051-generic-manifest-fast-path-gate.md) | generic manifest fast pathを独立評価するゲート |
| [0052](0052-literal-build-extension-mapping.md) | literal build extension mapping |
| [0053](0053-capture-group-build-extension-mapping.md) | capture group build extension mapping |
| [0054](0054-package-target-boundaries.md) | package target boundary |
| [0055](0055-generic-worker-kernel-cache.md) | generic worker kernel cache |
| [0056](0056-package-owned-target-graph.md) | package-owned target graph |
| [0057](0057-target-scc-phase-semantics.md) | target SCC phase semantics |
| [0058](0058-watch-reuse-resolved-frontend.md) | watchでresolved frontendを再利用 |
| [0059](0059-multiple-build-extension-mappings.md) | 複数build_extensions mapping |
| [0060](0060-post-process-builder-generic-subset.md) | generic PostProcessBuilder subset |
| [0061](0061-aot-worker-cache.md) | AOT worker executable cache |
| [0062](0062-ci-aot-prewarm.md) | CI AOT prewarm |
| [0063](0063-local-background-aot.md) | local background AOT |
| [0064](0064-evaluation-and-distribution-gate.md) | 評価matrixとdistribution gate |
| [0065](0065-launcher-and-release-artifact-boundary.md) | launcher/packageとrelease artifactの責務境界 |
