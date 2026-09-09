# Roadmap

`build_runner_accelerator` の作業継続用タスクリスト。現在の実装範囲を保ったまま、
対応builderを段階的に増やし、任意builderの動的ロードを段階導入する。

## 現在のベースライン

- [x] Rust frontend + Dart worker の責務分離
- [x] `json_serializable` と `source_gen|combining_builder` の2 phase
- [x] `freezed` の source builder と `json_serializable` 併用
- [x] snapshot / action graph / incremental dirty判定
- [x] resolver・glob・実read dependency の追跡
- [x] overlay と全成功後の atomic commit
- [x] native watch と worker再利用
- [x] binary asset read / build result と `build_batch`
- [x] `jobs=2` の phase内 batch 並列化
- [x] stockとのbyte比較、no-op、failure、delete、rename、watchの検証

## 次の実装順序

### 1. 複数builder向けの共通モデル — P0 完了

- [x] `BuilderDefinition` を導入する
  - builder ID（worker catalogとの対応）
  - input・output extension / pattern
  - `build_to`
  - phase / order
  - required inputs
  - resolver利用有無と出力数の制約
- [x] `build.yaml` の対応subsetをbuilder定義から解釈する
- [x] `BuildSpec`、action graph、deleted actionをbuilder IDの固定matchから解放する
- [x] 複数output、cache/source output、downstream overlayを共通処理にする
- [x] 未対応の構文・builderは従来どおり保守的にDart fallbackする
- [x] 実装と同じコミットにADR-0039を追加する

完了条件: 既存の `json_serializable` fixtureで、生成物・incremental・failure
semanticsが変更前と一致し、builder固有の特別処理が増えていないこと。

### 2. `freezed` builder — P0 完了

- [x] worker packageへ必要な依存とfactoryを追加する
- [x] build.yamlから生成manifestへ解決できることを確認する
- [x] `*.freezed.dart` を含む最小fixtureを追加する
- [x] `build_to: source` と出力削除・再生成を検証する
- [x] stock/Rustのclean、no-op、1-file、全入力変更を比較する
- [x] failure、rename、watch、依存変更のcorrectness caseを追加する
- [x] `json_serializable` と同じpackage内で併用できることを確認する

Freezedはannotationのない入力では正常に出力を生成しないため、builder definitionに
optional outputを持たせ、既存出力の削除もatomic commitへ含めています。同一phaseの古い
`.freezed.dart`はworkerのresolver/read viewから隠し、source outputを使う後続phaseの前に
resolver graphだけをresetします。検証は`scripts/correctness_freezed.sh`、
`scripts/watch_smoke_freezed.sh`、`scripts/benchmark_freezed.sh`で行います。

### 3. `riverpod_generator` — P1

- [x] worker packageへ必要な依存とfactoryを追加する
- [x] builder catalogとbuilder definitionへ登録する
- [x] annotationからの生成と`source_gen`のshared-part / combining経路をfixture化する
- [x] 複数generatorとcombining builderのphase・入力・出力関係を検証する
- [x] `json_serializable` / `freezed` との併用時の出力衝突・依存無効化を検証する
- [x] stock/Rust比較、incremental、failure、watch、benchmarkのスクリプトを追加する

`riverpod_generator`は`riverpod_generator 3.0.3`を使い、`.riverpod.g.part`をcacheへ出力する
shared-part builderとして扱う。現行のAnalyzer 8系との互換性を保つため、4.xではなく3.0.3を
固定している。stock/Rustの実行比較は、依存パッケージを取得できる環境で
`scripts/correctness_riverpod.sh`、`scripts/watch_smoke_riverpod.sh`、
`scripts/benchmark_riverpod.sh`を実行する。

### 4. builder対応の正確性・性能マトリクス — P1

- [x] builderごとにclean / no-op / 1-file / broad incrementalを記録する
- [x] generated output、read dependency、glob dependency、affected action集合を比較する
- [x] worker起動、resolver初期化、asset RPC、IPC frame数を分解して計測する
- [x] 1-file incrementalの支配要因（worker/resolver起動またはAnalyzer）を特定する
- [x] Dart workerのactionごとにfactory / resolver取得 / builder実行 / resolver依存収集 / 結果組み立てを計測する
- [x] builder名に依存しないgenerated worker kernel cacheとdepfile invalidationを追加する
- [x] 実測なしに `--jobs` の既定値やcache方式を変更しない


2026-09-05にDart SDK 3.13.0、Rust 1.98.1、`JOBS=1`でFreezed 3.2.3 + json_serializable 6.11.2を単回計測した。生成物はbyte-identicalで、Rust no-opは`0.010s`（stock `1.589s`）だった。一方、cleanはRust `17.649s`（stock `15.643s`）、1-fileは`9.612s`（stock `3.060s`）、全入力変更は`10.027s`（stock `3.290s`）だった。metricsでは1-fileの`worker_initialize_us`が`7.932s`、Freezedの`run_builder_us`が`1.627s`で、filesystem/graphではなくdynamic workerのprocess initializeが支配要因だった。

このため、この段階ではFreezed専用のbuilder fast pathは追加しない。`builder_manifest.dart`は
約26.8KB・860行だが、warmなmanifest生成は約1秒であり、Rust cleanのworker initialize約8.1秒や
SDK summary約4.35秒より小さい。workspace固有dynamic workerにはbuilder名に依存しないkernel
cacheを追加し、初回コンパイル失敗時は従来scriptへfallbackする。`BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL`
も生成scriptへ適用できるようにした。builder固有fast pathは、汎用経路と同一fixture・同一SDKで
有意なwall time差が確認でき、かつfallback/correctnessを満たす場合だけ別経路として再評価する。
詳細はADR-0055に記録する。
`scripts/benchmark_matrix.sh`で3つの対応builderを同じ条件に揃え、
`BUILD_RUNNER_ACCELERATOR_METRICS=1`のworker lifecycle・resolver reset・asset RPC・IPC frame
metricsを同時に記録した。1.98.1での3回反復では、filesystem/graph stageは概ねms未満から
数十msに留まり、1-fileのRust wall timeはworker initializeとbuildの合計に支配された。
Freezed/Riverpodのcold buildではworker initializeが約5秒、JSONでは約1秒だった。
JIT kernel snapshotのinitialize handshakeは約0.24秒まで短縮できたため、起動経路を任意指定
できるようにした。さらに`BUILD_RUNNER_ACCELERATOR_METRICS=1`ではDart workerの`Dart metrics:`を
action単位で出し、build stageをfactory、resolver初回取得、`runBuilder`、resolver依存収集、
結果組み立てへ分解できるようにした。得られた内訳を次の最適化判断に使い、既定のjobs/cache
方式は反復測定で支配要因が確認できるまで変更しない。

### 5. Freezed / Riverpod の cold Analyzer resolver path — P1（重要度: 高）

- [x] worker起動時の`package_config`読み込みとresolver constructorを個別計測する
- [x] first resolver getをSDK summaryとSDK summary後のAnalyzer driver初期化に分解して出力する
- [x] `scripts/benchmark_resolver_cold_path.sh`でFreezed/Riverpodのclean caseを同じ条件で比較する
- [x] SDK summaryのcache hit / rebuild条件と、worker process間で再利用できる境界を確認する
- [x] summary生成を短縮・共有する候補を、SDK/package versionとworkspace isolationを壊さずに検証する
- [ ] 改善候補ごとにstock比較、no-op、incremental、failure、watchを再実行する

Freezed/Riverpodのcold pathは、現時点の計測ではAnalyzer driver生成よりSDK summary経路が支配的
だった。`build_resolvers`のsummaryは`.dart_tool/build_resolvers/sdk.sum`へ保存され、SDK、
Analyzer、`build_resolvers`のmetadataが一致するcache hitは数msで完了する。一方、cacheが
空の`JOBS=2`ではworkerごとに同じsummaryを生成していたため、`sdk.sum.lock`を使って
workspace内のrebuildをsingle-flight化した。lock後の再確認により、一方のworkerだけが約5秒の
生成を行い、他方は生成済みsummaryを数msで再利用する。wall timeの支配要因は生成そのものに
残るため、workspaceをまたぐ事前生成/global cacheは互換キーを定義してから別途検討する。
測定のためにresolverをeager warm-upしたり、通常のworker lifecycleを変えたりしない。

### 6. 現行 stable build_runner の再ベースライン — P0 完了

- [x] `build_runner 2.16.1` と current `json_serializable 6.14.1` の10入力fixtureを追加する
- [x] Dart SDK、依存lock fingerprint、fixture fingerprint、cache、実行モードを記録する
- [x] clean / no-op / 1-file / broad と raw stdout/stderr をJSONLへ保存する
- [x] wall / user / sys / peak RSS を同一process helperで計測する
- [x] current runtimeへworkerをrebaseし、同一fixture・同一SDK・同一cacheでstock/fastを再計測する
- [x] worker再利用、resolver lifetime、ResourceManager、stateful builderの差分を検出するfixtureを追加する
- [x] fixtureで検出したbuilder instance / ResourceManager lifetimeをcurrent workerで一致させる
- [x] current `json_serializable` fixtureでclean / no-op / 1-file / broadのstock/Rust byte比較を行う
- [x] current `json_serializable` fixtureでwatchの入力変更 / 生成物削除 / renameをstock/Rust比較する
- [x] fast workerのjobs=1/2/4を同一fixture・同一cacheで計測する
- [x] opt-in AOT worker executable cacheとAnalyzer向けSDK facadeを追加する
- [x] AOT workerの初回compile、cache再利用、worker source変更時の再compileを検証する
- [x] AOT workerでcurrent fixtureのcorrectness、watch、warm incrementalを測定する
- [x] ローカルのAOT cache missではscript workerを先に起動し、AOT compileをbackgroundで進める
  - [x] `BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background` と per-workspace lock を追加する
  - [x] 初回 build の script fallback、detached compile、次回 AOT reuse を検証する
  - [x] watch の次回 rebuild で完成済み AOT worker へ切り替える
- [x] CI向けAOT prewarm/prebuildを追加し、compile完了を待って成果物をcacheへ保存する
  - [x] manifest / `dynamic_worker.dart`生成後にAOTだけを同期実行するprewarm入口を用意する
  - [x] AOT executable、depfile、SDK metadata、generated worker / manifestを後続jobからrestoreできるようにする
  - [x] cache miss / hit、複数workspace共有、worker source変更、SDK facade再bindを検証する
- [x] CI runner間で再利用できるAOT cache identity（OS・arch・SDK互換性・worker manifest）を定義する
- [x] AOTを既定経路にするための複数SDK / platform / workspace評価の実行基盤を追加する
- [ ] Linux上で代表workspace/SDKの実測を拡張する
- [x] リリース・配布方式の選択肢とCI integration前のrelease spikeを整理する

現行版Freezed 4.0.1は、`build_runner 2.16.1`と解決するとAnalyzer制約が衝突するため、
最初のstock基準はcurrent `json_serializable`で固定する。`scripts/benchmark_current_baseline.sh`
は、現行build_runnerが提供しない旧`--jobs`をstock側で仮定せず、default / force-jit /
force-aot / low-resourcesを別modeとして測定できる。`LANE=fast`を指定すると、同じ
fixture・SDK・cacheでRust workerの`FAST_JOBS=1/2/4`を測定する。

現行runtimeへのrebaseでは、`build_runner 2.16.1`の`ResolversImpl`、`BuilderFilesystem`、
`BuildStepImpl`、`ResourceManager`をworker境界内で再利用する。`source_gen:part_cleanup`は
current `build_config`でdeprecatedな`input_extensions`が未設定になるため、factory/import/keyを
検証した狭い互換ブリッジで`.g.part`を登録し、post-processのprimary input削除だけをRustの
atomic commitへ渡す。通常Builderの削除やprimary input以外の削除は引き続き拒否する。

初回計測では、fast jobs=1のclean/no-opはstockより短い一方、1-file/broadは約1.4秒でstockの
約0.78秒を上回り、jobs=2/4でも短縮しなかった。3回反復でもこの傾向は変わらず、cleanの
median wallはjobs=1/2/4で11.23/11.55/12.43秒、1-fileは1.38/1.39/1.56秒、broadは
1.33/1.38/1.70秒だった。current JSON fixtureのwatch（入力変更、生成物削除、rename）も
stock/Rust一致を3回確認した。したがってDAG/streaming schedulerやbuilder専用fast path、
jobs既定値の変更はまだ行わない。

2026-09-06に、生成workerのAOT executable cacheをopt-inで追加した。AOTの直接handshakeは
script/kernel/AOTで9.49/0.178/0.009秒、current JSONのwarm incrementalはjobs=1で
one-file 87.7ms、broad 101.7msの3回中央値になった。初回cleanはAOT compile込みで26.51秒
だったため、AOTはまだ既定化せず、CI prewarmでcompile待ちを分離する。`aot-cache-key`
はabsolute pathを含まないOS/arch・SDK・manifest・worker・package identityを出力し、
`aot-prewarm`は同期compile後にexecutable、depfile、metadata、generated worker/manifestを
cache可能な状態で公開する。2つの移設workspaceでcache keyの一致、AOT再compileなしの再利用、
SDK facade再bind、worker source変更時の無効化を確認した。次はFreezed/Riverpodを含むcold Analyzer pathで、AOTによる起動短縮と
SDK summary / Analyzer stateの重複を分けて測定する。

## 任意builderの動的ロード — P1（重要度: 高）

任意builder対応の本線は、人気builder名をRust/Dart workerへ組み込むことではなく、公式のPackageGraph / BuildConfig解決結果をworkspace固有のmanifestとworker entrypointへ変換することにする。Rustのaction planningはmanifestだけを入力にし、人気ツールは汎用経路の検証fixtureとして扱う。

- [x] 公式のPackageGraph / BuildConfigでbuilder import / factory / build extension / optionを解決する
- [x] workspaceごとにbuilderを静的importしたworker entrypointを生成する
- [x] build_runner_coreの解決情報と既存Dart workerのIPC / isolate境界を再利用する方式を確定する
- [x] package_configと全packageのbuild.yamlをfingerprintし、manifest stale時だけ再生成する
- [x] builder IDをpackage:builderの完全な識別子としてmanifest・worker・action graphで共有する
- [x] Rust側のbuilder定義をmanifest由来のowned modelにし、組み込みbuilder catalog / YAML parserを本線から除去する
- [x] 複数outputを共通manifest・action planning・overlay・atomic commitへ渡す最小経路をfixtureで確認する
- [x] source/cache、phase、required inputのmetadataを共通定義としてRustへ渡す
- [x] cache builderとrequired inputを持つ後段builderの2-builder fixtureでphase・overlay・cache再生成をstock比較する
- [x] 動的ロード失敗時のauto fallbackと、--mode rustのエラー境界を実装する
- [x] 任意builderの最小fixtureと、一回でbyte比較・no-opまで確認する短い検証スクリプトを追加する
- [x] 任意builder fixtureでstockとの生成物削除・入力削除・rename semanticsを実行確認する
- [x] 任意builder fixtureでstockとのaffected action setを比較する
- [x] 任意builder fixtureでfailure/recovery semanticsを比較する
- [x] 任意builder fixtureでstockとのwatch（生成物削除・入力変更・rename）semanticsを比較する
- [x] 任意builder fixtureでatomic-save semanticsを比較する
- [ ] 複雑なextension、外部プロセスを段階的に追加する
- [x] cache-onlyの単純なPostProcessBuilderを汎用manifest・最終phase・dynamic outputへ渡し、stock比較する
- [x] `generate_for.exclude` のglobをmanifestとaction candidate selectionへ渡し、stock比較する
- [x] root targetの` sources` include/excludeをmanifestとaction candidate selectionへ渡し、stock比較する
- [x] literal full-pathの`build_extensions`をmanifestとaction planningへ渡し、stock比較する
- [x] `{{name}}` capture group（複数group、`^` anchor、greedy suffix match）のmappingをmanifestとaction planningへ渡し、stock比較する
- [x] 同一builderの複数`build_extensions` keyを共通manifestとaction planningへ渡し、重複matchの出力unionをstock比較する
- [x] direct dependency packageの`auto_apply: dependents` builderをroot targetへ適用し、required input・phase・cache/sourceをstock比較する
- [x] 複数builderが同じoutput AssetIdを宣言した場合、worker起動前にstock同様のconflict errorで停止する
- [x] manifest workerのkernel cacheをbuilder非依存で生成し、depfileの依存更新時に再生成する
- [x] dependency package-owned target、依存順を持つ複数target graph、package-aware asset scanの適用関係をstock比較する
- [x] target cycle/SCCをbuild_runnerと同じphase semanticsで扱う
- [x] watchの再ビルドで解決済みWorkspace/manifestをbuildへ再利用し、fingerprint/read/parseの重複を除く
- [ ] 人気ツール向けfast pathを追加する場合は、汎用manifest経路と分離し、同一fixture・同一SDKで有意な速度差を計測する
- [x] 実装と同じコミットに動的ロード専用のADRを追加する

現在の対応subsetは、optionalではない通常のBuilder、rootまたはdirect dependency packageから解決できる`package:` import、factory一つ、単純なinput/output suffix（複数可）、literal full-path mapping、capture group mapping（1つの`build_extensions` key内で複数named group可）、同一builderの複数`build_extensions` key、最大一つのrequired input、include/excludeのgenerate_for、targetごとのinclude/exclude sources、JSONへ変換可能なoptionです（build_extensionsを変更するoptionとoptional builderは除外）。複数mappingが同じ入力にmatchした場合はbuild_runnerと同じaction内の出力unionとして扱います。依存targetを含む複数target graphは、公式target依存のSCCを依存先優先で展開し、SCC内では全体のbuilder順と安定したtarget member順で実行し、target/package/builder/inputをaction keyへ含めます。dirty actionが生成した古いoutputは新しいresultがoverlayへ入るまで隠します。通常のBuilderに加えて、cache-onlyで単純なドット付き`input_extensions`を持つPostProcessBuilderは、通常builderの出力を最終phaseのprimary inputとして受け、dynamic outputを生成できます。PostProcessBuilderの出力は通常builderのcandidate sourceから隠します。非root targetのsource output、capture groupの不正なpath・重複参照、複雑なPostProcessBuilder、外部プロセスは未対応のため、autoではDart fallback、rustではエラーになります。選択済みaction間の同一output AssetIdはstock同様のconflict errorとしてRustでもworker起動前に拒否します。

実行確認は、まずDart workerのanalyzeと既存quickを走らせた後、必要なときだけVERIFY_ARBITRARY_BUILDER=1を追加します。現段階では任意builder fixtureで複数builder・複数出力のstock/Rust byte比較、Rust no-op、生成物削除、入力削除、rename、failure/recovery、affected action set、`generate_for.exclude`、root target sources、literal full-path extension、capture group mapping、atomic-save、duplicate output conflictを確認済みです。`scripts/correctness_arbitrary_builder.sh`はstock用とRust用を一時workspaceに分離し、`CASE_FILTER`で個別ケースを短く再実行できます。`scripts/correctness_multi_mapping_builder.sh`では一つのbuilderにsuffixとliteral mappingを持たせ、同一入力の出力union、no-op、変更、rename、deleteをstock/Rustで比較済みです。`scripts/correctness_capture_builder.sh`では複数named group・`^` anchor・no-op・変更・rename・deleteを比較し、`scripts/watch_smoke_arbitrary_builder.sh`ではcapture outputを含むstock/Rustのwatchについて生成物削除、atomic save、renameを比較済みです。`scripts/correctness_arbitrary_package_target_builder.sh`ではdirect dependencyの`auto_apply: dependents`、root target source boundary、required-input phaseを比較し、`scripts/correctness_arbitrary_dependency_target.sh`ではdependency-owned target、root targetとの複数target順序、package-aware cache、target単位のincrementalを比較済みです。`scripts/correctness_target_cycle.sh`では同一builderを持つ2 targetのSCCについて、member phase order、stale output hiding、upstream dirty propagation、no-op、delete-only cleanupを比較済みです。`scripts/correctness_post_process_builder.sh`ではcache-only PostProcessBuilderのdynamic output、no-op、入力変更、rename、入力削除、stale output cleanupをstock/Rustで比較し、`scripts/watch_smoke_post_process_builder.sh`では入力変更とrenameを比較します。複雑なpost-process、外部プロセスなどは引き続き未対応です。

## 後段で再評価する項目

- [ ] 条件付きimport/exportの依存記録を全候補から実選択候補へ精密化
- [ ] 大きなbuild resultのchunking
- [ ] AssetGraphのindexed/lazy化
- [ ] worker数の自動選択とbuilder別のコストモデル
- [ ] 実プロジェクトでの混在builder・複数package検証

## 作業ルール

性能・互換性・protocol・graph・phase・scheduler・builder実行境界に関する判断は、
実装と同じコミットにADRを添える。各builderの完了条件は、manifest生成だけではなく、
stock比較、correctness、incremental、watch、benchmarkまで含む。
