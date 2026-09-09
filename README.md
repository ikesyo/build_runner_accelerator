# build_runner Rust frontend PoC

`build_runner` の実行モデルを保ったまま、ファイル走査・差分判定・依存グラフ・成果物コミットを Rust 側へ寄せる最小 PoC です。既定workerでは、対応subsetのbuilderをbuild.yamlから解決する段階的なdynamic loadingも行います。

## Project-facing package

The release spike exposes one Dart package, `build_runner_accelerator`, which
contains the launcher, manifest generator, and compatible worker runtime.
Project-local usage is:

```yaml
dev_dependencies:
  build_runner_accelerator: ^0.1.0
```

```bash
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
```

The launcher selects a cached native frontend in `--mode auto`, downloading the
matching versioned GitHub Release artifact on a cache miss. The detached
Ed25519 manifest signature and artifact SHA-256 are verified before the binary
is installed into the user cache. If the native frontend or manifest subset is
not available, `--mode auto` falls back to stock Dart `build_runner`; `--mode
rust` makes those cases errors, while `--mode dart` always selects the stock
path. The release target matrix and cache boundaries are described in
[`doc/launcher-and-release.md`](doc/launcher-and-release.md).

作業継続時は [AGENTS.md](AGENTS.md) と [docs/roadmap.md](docs/roadmap.md) を先に確認してください。

## 今回の実装スコープ

builder名をRust/Dart workerへ組み込むことを本線にせず、build_runnerの公式 `PackageGraph` / `BuildConfig` 解決結果からworkspace固有のmanifest v2とworker entrypointを生成します。Rust側はbuilder ID、入力・出力、phase、build_to、依存情報をmanifestから読み込み、人気builderも任意builderも同じaction planningへ渡します。

現在のfixtureで検証している代表例は `freezed`、`json_serializable`、`riverpod_generator` と `arbitrary_builder_app` です。前3者は「組み込みカタログだから特別扱いする」のではなく、通常のbuild.yaml定義が汎用manifest subsetに入る例として扱います。

| manifest field | 役割 |
| --- | --- |
| builder ID | `package:builder` の完全な識別子とfactory catalogのキー |
| input / output suffixes | 1入力から生成される1つ以上の成果物 |
| phase / required input | builder orderingと後続phaseの入力 |
| build_to | sourceまたはcacheへの出力先 |
| generate_for / options | build_runnerが解決した適用範囲とbuilder options |

人気ツール向けfast pathは将来的に追加できますが、測定で効果が確認できる場合だけ、manifest経路の外側の独立した最適化として扱います。fast pathが不成立・不整合の場合も、汎用manifest経路を正しさの基準にします。

Rust frontend は次を担当します。

- package config と package asset の解決
- root package のスナップショットと、前回記録した依存 asset の再検査
- action graph の dirty 判定、削除検知、フェーズ順序
- Dart worker との length-prefixed IPC（制御はJSON、asset `read`とbuild result成功応答は単一バイナリフレーム）
- `--jobs N` 指定時は phase の action 数に応じて worker を遅延起動・縮小し、複数worker時はready actionを連続batchへ分割してworkerあたり1回の`build_batch`で処理
- cache/source への atomic commit と、全 action 成功後の graph 保存
- action graphは`.dart_tool/build_runner_accelerator/graph-v3.bin`へ小さなversioned binary形式で保存し、内容が変わらないno-opでは再書き込みしない
- `watch` の native filesystem event による変更検知と、1プロセス内で再利用する Dart worker

Dart worker は次を担当します。

- workspace固有manifestから生成されたfactory catalogの解決（worker本体はbuilder packageを静的依存しない）
- `BuildStep` / `AssetReader` / `Resolver` の実行
- Analyzer の in-memory filesystem への同期
- builder が実際に読んだ asset の返却
- Analyzer の条件付き import/export 候補を含む resolver 依存の返却
- 同一workerのreset区間に限ったasset read bytesとpositive `canRead`結果の共有cache（missingはcacheしない）
- asset `read`成功応答のraw bytes受信（現行worker protocolではbinary capabilityを必須化）
- build resultのoutputsをraw bytesで受信（single/batchともbinary capabilityを必須化）

## 最小構成

```text
rust/
  src/{main.rs,assets.rs,build.rs,builder.rs,cli.rs,frontend.rs,graph.rs,metrics.rs,plan.rs,protocol.rs,snapshot.rs,watch.rs,worker.rs,workspace.rs}
dart_worker/
  bin/{generate_builder_manifest.dart}
  lib/{worker.dart,builder_manifest.dart,remote_build_step.dart,resolver_host.dart,resolver_reads.dart,protocol.dart}
fixtures/{json_serializable_app,freezed_app,riverpod_app,arbitrary_builder_app}/
scripts/{smoke.sh,verify.sh,correctness_arbitrary_builder.sh,benchmark_{json_serializable,freezed,riverpod,matrix,resolver_cold_path}.sh,correctness_{json_serializable,freezed,riverpod}.sh,watch_smoke{,_freezed,_riverpod}.sh}
```

Rust と Dart の境界は `protocol/v1.md` に固定しています。標準出力は IPC 専用、診断は標準エラー出力へ流します。

## SDK と依存関係

この作業環境では、リポジトリ直下のローカル SDK と Pub cache を使用します。

- Dart SDK: `.toolchains/dart/dart-sdk`（3.13.3）
- Rust toolchain: `.toolchains/rustup` / `.toolchains/cargo`（1.98.1）
- Pub cache: `.pub-cache`
- `build`: 4.0.0
- `build_resolvers`: 3.0.4
- `build_runner_core`: 9.3.2
- `freezed`: 3.2.3
- `freezed_annotation`: 3.1.0
- `json_serializable`: 6.11.2
- `riverpod_generator`: 3.0.3
- `riverpod_annotation`: 3.0.3
- `riverpod`: 3.0.3
- fixture の比較対象 `build_runner`: 2.7.2

`build_resolvers` の依存制約に合わせ、PoC の Dart 依存は意図的に固定しています。SDK を別の場所に置く場合は `DART_BIN` を指定できます。

## 実行

```bash
export PUB_CACHE="$PWD/.pub-cache"
export DART="$PWD/.toolchains/dart/dart-sdk/bin/dart"
export RUSTUP_HOME="$PWD/.toolchains/rustup"
export CARGO_HOME="$PWD/.toolchains/cargo"

cd dart_worker
$DART --suppress-analytics pub get
$DART --suppress-analytics format --output=none --set-exit-if-changed lib bin

cd ../fixtures/json_serializable_app
$DART --suppress-analytics pub get

cd ../..
RUSTUP_HOME="$PWD/.toolchains/rustup" \
CARGO_HOME="$PWD/.toolchains/cargo" \
  "$PWD/.toolchains/cargo/bin/cargo" run --manifest-path rust/Cargo.toml -- \
  build --root fixtures/json_serializable_app \
  --dart "$DART" --mode auto
```

workerのcold startを短縮する場合は、Dart workerをJIT kernelへ事前コンパイルし、
`BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL`で指定できます。`build_runner_core`が`dart:mirrors`を
参照するため、AOT executableではなくkernel snapshotを使用します。

```bash
WORKER_KERNEL=$(bash scripts/compile_worker_kernel.sh)
BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL="$WORKER_KERNEL" \
  BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/debug/build_runner_accelerator" \
  "$PWD/rust/target/debug/build_runner_accelerator" build \
  --root fixtures/json_serializable_app --dart "$DART" --mode auto
```

kernelはworker source、依存lock、Dart SDKを更新した後に再生成してください。未指定時は
manifest生成後のworkspace固有`dynamic_worker.dart`を使用します。`--worker`で外部workerを指定する場合は、manifestのbuilder IDとIPC契約を満たすworkerを指定してください。

2回目は `No work to do (Rust frontend)` になります。再現可能な smoke test は次で実行できます。

```bash
bash scripts/smoke.sh
```

開発中の検証ループは `verify.sh` を使います。既定のquick levelはDart workerのanalyzeとstockとのbyte比較/no-opを実行します。full suiteより短い確認として、コード変更ごとに使えます。watch smokeも確認する場合は`VERIFY_WATCH=1`を追加します。

```bash
bash scripts/verify.sh
VERIFY_WATCH=1 bash scripts/verify.sh
```

任意builderのdynamic loadingだけを短く確認する場合は、専用fixtureでstockとのbyte比較、
Rust初回build、2回目no-opを行います。通常のquickには含めず、必要なときだけ
VERIFY_ARBITRARY_BUILDER=1を追加します。

```bash
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
# または専用スクリプトだけを実行
bash scripts/correctness_arbitrary_builder.sh
```

`verify.sh`は開始時にRust frontendを一度だけbuildし、quick・targeted・fullの子script
から同じバイナリを直接再利用します。既に検証済みのバイナリを使う場合は
`BUILD_RUNNER_ACCELERATOR_BIN=/absolute/path/to/build_runner_accelerator`を指定できます。Rust unit
test、Dart analyze、stock/Rustの生成物比較は省略しません。benchmark単独実行も、測定区間の
外でRust frontendを一度だけbuildします。詳細は[ADR-0035](docs/adr/0035-reuse-prebuilt-rust-binary-in-verification.md)を参照してください。

互換性ケースを絞るtargeted levelでは、rollbackとresolver依存を確認する既定値以外も、`VERIFY_CASES`で指定できます。correctness caseはstock/build_runnerのprocess状態を共有しない逐次実行で、各caseを同期対象外の一時workspaceへ隔離して実行します。

```bash
VERIFY_LEVEL=targeted \
VERIFY_CASES=generated-output-delete,failure,conditional-dependency \
  bash scripts/verify.sh
```

リリース前はwatch smokeを含むquick checksに続けて、JSONの10ケースとFreezedの
stock/Rust比較ケースを逐次実行するfull levelを使います。benchmarkまで同時に行う場合だけ
`VERIFY_BENCHMARK=1`を追加します。

```bash
VERIFY_LEVEL=full bash scripts/verify.sh
VERIFY_LEVEL=full VERIFY_BENCHMARK=1 \
  bash scripts/verify.sh
```

計測は、独立fixtureに対して次で実行できます。stock `build_runner` と Rust frontend の clean/no-op/1-file/全入力変更を計測し、各ケースで生成物を比較します。`COUNT` を指定すると追跡済み基準fixtureから10/100/500入力fixtureを必要時に自動生成します。設計理由は[ADR-0018](docs/adr/0018-reproducible-scale-benchmark-fixtures.md)に記録しています。

```bash
bash scripts/benchmark_json_serializable.sh

COUNT=100 JOBS=1 bash scripts/benchmark_json_serializable.sh
COUNT=500 JOBS=1 bash scripts/benchmark_json_serializable.sh

# 並列workerの比較（既定値は1）
JOBS=2 bash scripts/benchmark_json_serializable.sh
JOBS=4 bash scripts/benchmark_json_serializable.sh

# Freezed + json_serializable併用fixture
bash scripts/benchmark_freezed.sh

# Riverpod + Freezed + json_serializable併用fixture
bash scripts/benchmark_riverpod.sh

# 3 builderを同じ条件で計測し、結果をまとめて表示
bash scripts/benchmark_matrix.sh

# Freezed/Riverpodのcold Analyzer resolver初期化を段階計測
bash scripts/benchmark_resolver_cold_path.sh

# 複数worker間のSDK summary再生成を確認
JOBS=2 bash scripts/benchmark_resolver_cold_path.sh
```

計測値は wall/user/sys、cache使用量を出力します。実行環境にGNU `time` がない場合は `maxrss_kb=unavailable` になります。`IO_METRICS=1` を付けると、ptraceが許可された環境ではread bytes/open countも取得します。生成物のbyte-identicalとRust no-opも各計測で検証します。

Rust frontend内のworker lifecycleとIPC粒度を確認する場合は、stderr-onlyのruntime metricsを有効にします。

```bash
BUILD_RUNNER_ACCELERATOR_METRICS=1 COUNT=100 JOBS=2 \
  bash scripts/benchmark_json_serializable.sh
```

`workers_active`、workerのstart/initialize/reset累積数、worker起動・initialize・reset・resolver reset・build・asset RPCの経過時間、IPC frame数/bytes、build result frame数/bytes、旧JSON換算のbuild result bytes、asset RPC、asset `read` bytes、binary read応答数を出力します。さらに`Rust filesystem metrics:`としてroot scan、generated/dependency/glob asset追加、dirty判定、build後scanの時間と初回scanのasset数/bytesを、`Rust graph metrics:`としてgraphのload/decode時間、saveのencode/write/rename時間、読み書きしたfile bytes、no-opでsaveを省略したかを、`Rust workspace metrics:`としてbuild-scoped asset read cacheのhit/missを出力します。これはprotocol payloadではなく、通常のstdoutと生成物には影響しません。`read_bytes`はRustがasset responseとして返したpayload bytes、`build_result_bytes`はRustが受信したbuild result binary frame bytes、`build_result_json_bytes`は同じ結果を旧JSON bytes配列で送った場合の想定frame bytes、`IO_METRICS=1`のread bytesはOS syscallレベルの値です。builder横断の標準計測には`benchmark_matrix.sh`を使えます。判断の履歴は [`docs/adr/`](docs/adr/README.md) にまとめています。
`BUILD_RUNNER_ACCELERATOR_METRICS=1`ではDart workerもactionごとに`Dart metrics:`をstderrへ出力し、builder factory、resolver取得（初回と累積）、`runBuilder`、resolver依存収集、結果組み立ての経過時間とoutputs/reads件数をJSONで記録します。protocol payload、通常のstdout、生成物は変更しません。
resolverを初めて取得したworkerでは、追加で一行の`Dart resolver metrics:`を出力し、
`package_config`読み込み、resolver constructor、SDK summary、SDK summary後のAnalyzer driver
初期化を含む残りの時間を記録します。`benchmark_resolver_cold_path.sh`はFreezed/Riverpodの
clean caseでこの一行を抽出します。SDK summary後の値はfirst resolver getからSDK summaryを
差し引いた診断値であり、warm-upやresolver lifecycleの変更は行いません。SDK summaryは
Analyzerが`dart:core`などSDKの宣言・型情報を毎回ソース解析せずに読み込むためのシリアライズ済み
bundleで、`build_resolvers`が`.dart_tool/build_resolvers/sdk.sum`へcacheします。cacheが空または
古い場合の生成は数秒かかるため、build_runner_acceleratorは`JOBS=2`以上のworker間で
`.dart_tool/build_resolvers/sdk.sum.lock`を使って再生成を一つにまとめます。metricsの
`resolver_sdk_summary_lock_wait_us`と`resolver_sdk_summary_after_lock_us`で待機と、lock後の
cache hit/generationを分けて確認できます。valid cacheはworkspace単位で扱い、SDK/package
versionが異なるsummaryを別workspaceへ無条件に共有しません。

2026-09-03の単回測定では、10入力では`jobs=2`が1-file/全変更で有利でした。100入力ではcleanがRust `jobs=1/2/4`でそれぞれ`8.794/6.177/5.809s`、全変更が`5.627/4.962/5.249s`でした。no-opや1-fileではworkerを増やす効果が小さく、workerごとのread重複も増えるため、`--jobs`の既定値は1のままです。大規模clean/全変更の実験時だけ`--jobs 2`を比較対象にします。測定条件とmetricsは[ADR-0014](docs/adr/0014-benchmark-guided-worker-parallelism.md)に記録しています。

positive `canRead` cache追加後の100入力・`jobs=1`では、`can_read` requestsが514から313、asset requestsが927から726、IPC framesが930から729へ減少しました。続くasset `read` binary envelopeは、readごとのframe数を増やさずJSON bytes配列をraw bytesへ置き換えます。今回の100入力runではRust→Dartの`ipc_bytes_sent=286,033`、`binary_read_responses=313`（`read_requests=313`）でした。直近のJSON配列runの722,408 bytesと比べた参考値は約60%減です。現行PoCでは非対応workerへのJSON fallbackは持たず、capability不足を初期化時にエラーにします。wall timeの改善は同一fixtureの反復benchmarkで確認します。詳細は[ADR-0015](docs/adr/0015-reset-scoped-positive-can-read-cache.md)、[ADR-0017](docs/adr/0017-binary-asset-read-response.md)、[ADR-0019](docs/adr/0019-require-binary-asset-read-capability.md)に記録しています。graph persistenceのstage計測は[ADR-0022](docs/adr/0022-graph-persistence-stage-metrics.md)、indexed/lazy化を見送る判断は[ADR-0023](docs/adr/0023-defer-indexed-asset-graph.md)に記録しています。100入力・`jobs=1`ではgraph fileが147,895 bytes、graph stageはno-opで1.341 ms、1-fileで2.119 ms、全入力変更で2.874 msでした。

build resultも`BRAR` binary frameへ移行し、metadataにoutputsのasset/lengthとincremental判定用のreadsを残し、bytes本体は1フレーム内に連結します。100入力・`jobs=1`では、binary frameが194,278 bytes、旧JSON換算が417,128 bytesで、53.4%削減でした。workerは`build-result-binary-v1` capabilityを必須で広告し、JSON build resultへのfallbackは持ちません。transportはRustが所有する子workerとのstdin/stdout pipeを維持します。stdoutはログではなくlength-prefixed IPC専用、診断はstderrです。build result binary化の判断は[ADR-0024](docs/adr/0024-binary-build-result-payload.md)、transportの判断は[ADR-0025](docs/adr/0025-stdio-pipe-transport.md)に記録しています。
BRARのDart worker送信では、`writeAsBytes`境界で一度だけ防御copyした`Uint8List`を
output chunkとして保持し、batch全体を別配列へ連結せず同じ1 frameへ順番に書き込みます。
Rust側も受信frameのraw bufferをdecode完了まで保持し、中間copyを省いています。判断は
[ADR-0026](docs/adr/0026-retain-binary-frame-buffer.md)、[ADR-0027](docs/adr/0027-symmetric-ipc-frame-limit.md)、
[ADR-0028](docs/adr/0028-stream-build-result-output-chunks.md)に記録しています。asset `read`の
BRABもDart側でraw bytes viewをcacheし、builderへ返す境界でのみ防御copyする方針にしています
（[ADR-0029](docs/adr/0029-zero-copy-asset-read-view.md)）。

filesystem metrics導入後の100入力・`jobs=1`では、tracked glob stageが約316–331msから
約29–34msへ下がりました。`findAssets`のbuild-scoped cacheと、非再帰globのallocation-free
matcherの判断・測定は[ADR-0030](docs/adr/0030-filesystem-stage-metrics-before-scan-optimization.md)、
[ADR-0031](docs/adr/0031-build-scoped-find-assets-cache.md)、[ADR-0032](docs/adr/0032-linear-segment-glob-matcher.md)
に記録しています。これは単回benchmarkの参考値であり、全ケースで生成物のbyte-identicalと
Rust no-opを確認しています。

500入力・`jobs=1`ではroot scanが約10.5–12.5msに留まったため、mtime/sizeをgraphへ持ち込む
metadata fast pathは見送りました。一方、sorted asset indexのliteral prefix検索により、
tracked glob stageは約660–712msから約49–71msへ下がりました。測定と判断は[ADR-0033](docs/adr/0033-defer-metadata-digest-fast-path.md)、
[ADR-0034](docs/adr/0034-prefix-indexed-glob-candidates.md)に記録しています。

同じ500入力fixtureの全入力変更では、`jobs=1`の約10.925sに対して`jobs=2`が約8.030s、
1-fileでは約2.205sに対して約1.978sでした。no-opは約0.124s対約0.126sで差がなく、
`jobs=2`のall-file runではworker 2個・asset requests 3,552・read requests 1,526に
増えています。そのため`--jobs`の既定値は1のまま、500入力以上の性能比較で`JOBS=2`を
明示する判断を[ADR-0036](docs/adr/0036-500-input-worker-parallelism-measurement.md)に
記録しています。

変更時の互換性検証は次で実行できます。生成物削除、入力削除、リネーム、失敗時のgraph/output保持と診断、複数入力での影響action集合、`findAssets`の一致ファイル追加、条件付きimport候補の追加をstockとRustで比較します。

```bash
bash scripts/correctness_json_serializable.sh
bash scripts/correctness_freezed.sh
bash scripts/correctness_riverpod.sh

# native watcher: generated output deletion + source edit
bash scripts/watch_smoke.sh
bash scripts/watch_smoke_freezed.sh
bash scripts/watch_smoke_riverpod.sh
```

watch はRustのnative filesystem eventと常駐Dart workerを使います。`--interval-ms` はイベントのdebounce時間です。停止は `Ctrl-C` です。

```bash
cd fixtures/json_serializable_app
PUB_CACHE="$PWD/../../.pub-cache" \
RUSTUP_HOME="$PWD/../../.toolchains/rustup" \
CARGO_HOME="$PWD/../../.toolchains/cargo" \
  ../../.toolchains/cargo/bin/cargo run --manifest-path ../../rust/Cargo.toml -- \
watch --root . --dart ../../.toolchains/dart/dart-sdk/bin/dart --interval-ms 200
```

`--mode auto`（既定値）は、PoCが対応する形の`build.yaml`だけRust frontend
を使い、それ以外は`dart run build_runner build --delete-conflicting-outputs`
へfallbackします。`--mode rust`は未対応設定をエラーにし、`--mode dart`は
常に既存Dart実装を実行します。

既定workerのRust frontendは、最初にpackage_configとpackageごとの`build.yaml`から
workspace fingerprintを作ります。manifestがない、古い、または生成workerがない場合だけ、
Dartの`PackageGraph` / `BuildConfig`を使うgeneratorを起動し、
`.dart_tool/build_runner_accelerator/builder-manifest.json`と
`.dart_tool/build_runner_accelerator/dynamic_worker.dart`を生成します。dynamic workerは
builder packageの`package:` importとfactoryを静的importして既存のDart worker protocolを
呼び出すため、builder packageをworker packageへ手作業登録したり、build_runnerをforkしたり
する必要はありません。通常のno-opではmanifest generatorを再起動しません。

第一段階でRust frontendが解釈するdynamic builderは、optionalではない通常のBuilder、factory一つ、
`package:` import、単純なinput/output extension一組、最大一つのrequired input、
include-onlyの`generate_for`、JSONへ変換できるoptionです（`build_extensions`を変更するoptionとoptional builderは除外）。phaseはrequired input、
runsBefore、appliesBuildersを使ってgenerator側で安定順序化し、`build_to`とoptionを
manifestからRust/Dartへ渡します。複数output、post-process builder、複雑なextension、
exclude glob、target sources、optional builder、外部プロセス、target間の完全な適用関係は未対応です。

従来のbuilt-in builder（Freezed/json_serializable/Riverpod/source_gen）もdynamic
manifest経路から解決できます。別の`--worker`を指定した場合は既存の静的catalog経路を
維持します。対応外のbuilderやmanifest生成失敗は、`--mode auto`ではDart fallback、
`--mode rust`ではエラーになります。生成されたDart scriptには事前コンパイルkernelを
適用せず、workspace固有のimportが確実に読み込まれるようにしています。

## 現時点の制限

これは `build_runner` の汎用互換実装ではありません。次の拡張はまだ行っていません。

- dynamic builderの完全なbuild.yaml互換（第一段階は単純な1 input / 1 output、1 factory、include-only generate_for、JSON optionのsubset（build_extensionsを変更するoptionは除外））
- `findAssets` のglob監視は実装済みだが、build_runner本体のphase別glob可視性を完全には再現しないこと
- 条件付きimport/exportは安全側に全候補を依存として記録するため、選択されない候補の変更でもresolver actionを再実行すること
- 大規模fixture向けの並列schedulerのさらなるチューニング（`--jobs N` は実験的opt-in）
- `build.yaml` の完全な構文解析と、builder定義の完全な互換性（未対応形状はauto fallbackする保守的な判定）
- 大きすぎるbuild resultのchunking（現状は1 build/batch resultを1 binary frameで送る）
- build_runner 本体の AssetGraph バイナリ形式との互換（`graph-v3.bin`はPoC専用形式）

したがって、現在は「Rust が高速な frontend と incremental 判定を持ち、既存 Dart builder を worker として呼び出せるか」を測るための PoC です。
