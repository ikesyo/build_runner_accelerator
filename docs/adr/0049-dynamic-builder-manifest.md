# ADR-0049: build.yamlから生成するdynamic builder manifest

- Status: Accepted
- Date: 2026-09-05
- Context: 任意 builder 対応の第一段階
- Decision: default worker packageからworkspace固有のDart entrypointを生成する

## Context

現在のRust frontendは、Dart workerの静的catalogに登録したbuilderだけを
実行できる。builder packageを追加するたびにworker packageのimport、factory、
Rustのextension定義を手作業で変更すると、任意builder対応にならず、forkした
build_runnerとの追従コストも増える。

一方、builder factoryを実行時にdart:mirrors等で推測してロードすると、
package import、isolate、factory型、build.yamlの設定、failure fallbackの境界が
曖昧になる。Rust側でYAMLを再実装して設定を解釈するのも、build_runnerの
BuildConfigと異なる挙動を生みやすい。

## Decision

default worker (fast_build_runner_worker:fast_build_worker)を使う場合、Rust
frontendは次の順序で動作する。

1. package_config.jsonとpackageごとのbuild.yamlからworkspace fingerprintを作る。
2. manifestがない、fingerprintが古い、または生成workerがない場合だけ、Dartの
   generate_builder_manifest executableを一度起動する。
3. generatorは公式のPackageGraphとBuildConfigを使ってroot targetのbuilderを
   解決し、builderごとのpackage import、factory、extension、build_to、option、
   generate_for、phase順をmanifestへ書く。
4. generatorは解決したfactoryを静的importするworkspace固有の
   .dart_tool/fast_build_runner/dynamic_worker.dartを生成する。worker本体の
   IPC、BuildStep、AssetReader、Resolver実行は既存のrunWorkerを再利用する。
5. Rust frontendはmanifestを既存の共通BuilderDefinitionへ変換し、既存の
   snapshot、action graph、overlay、atomic commitをそのまま使う。

最初のsubsetは、optionalではない通常のBuilder、package import、factory一つ、単純なinput/output
extension一組、最大一つのrequired input、include-onlyのgenerate_for、JSONへ
変換可能なoption（build_extensionsを変更するoptionとoptional builderは除外）に限定する。複数output、post-process builder、複雑なextension、
exclude glob、target sources、外部プロセスなどはmanifest生成を失敗扱いにする。

--mode autoでは未対応形状・generator失敗・manifest不整合をDart build_runnerへ
fallbackし、--mode rustではエラーにする。--workerで別のworker executableを指定
した場合は、既存の静的catalog経路を維持する。生成entrypointはDart scriptとして
起動し、静的worker kernelを適用しない。これにより、workspace固有のimportが古い
kernelに隠れることを防ぐ。

## Consequences

- builder package側のfactory登録やbuild extensionのRust手書き追加なしに、対応subsetの
  builderをroot targetから実行できる。
- manifestはbuild.yaml/package config変更時だけ再生成し、通常のno-opではgeneratorを
  再起動しない。
- generated workerはworkspace内に置かれるが、repoへcommitする必要はない。
- 既存のIPCとworker lifecycleを保つため、stock build_runnerのAssetGraph形式や
  post-process semanticsを再利用するものではない。
- build_to: cacheの全形式、複数output、複雑なglob、package間target適用は次の段階で
  stock比較を追加する。

## Alternatives considered

- build_runnerをforkして生成scriptやAssetGraphを直接変更する: upstreamとの追従範囲が
  増え、今回避けたいforkを導入するため不採用。
- Rustからbuilder factoryを動的に反射ロードする: import/isolateとfactory型の
  安全な境界を定義しにくいため不採用。
- 静的catalogだけを拡張する: 任意builderの登録作業が残るため不採用。

## Verification boundary

最小fixture fixtures/arbitrary_builder_appと
scripts/correctness_arbitrary_builder.shで、stockとの生成物byte比較、Rust
初回build、2回目no-opを一回の短いループとして検証する。通常のverify.shのquick
経路には追加せず、VERIFY_ARBITRARY_BUILDER=1で明示的に有効化する。
