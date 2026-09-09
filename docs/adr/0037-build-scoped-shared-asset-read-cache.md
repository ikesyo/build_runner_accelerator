# ADR-0037: worker間でbuild-scoped asset read bytesを共有する

- Status: Accepted
- Date: 2026-09-04

## Context

ADR-0011とADR-0015で、Dart worker内の`read`とpositive `canRead`をreset区間の
cacheに限定した。これは同一worker内の重複RPCを減らすが、`--jobs 2`以上ではworker
ごとにcacheが分離されるため、同じ入力・既存cache outputをRustが複数回filesystemから
読み出す可能性がある。ADR-0036の500入力測定でも、worker間のread response重複が
parallelismのトレードオフとして残っている。

一方、builderから見えるasset readの意味はbuild中のfilesystem snapshotとoverlayで
決まる。worker間でbytesを共有しても、RPCの応答内容、read順序、observed dependencyの
記録、overlayの優先順位は変える必要がない。build終了後にfilesystemが変わり得るため、
watch iterationをまたぐcache共有は安全ではない。

## Decision

- `Workspace`にbuild単位の`AssetId -> Arc<Vec<u8>>` read cacheを追加する。
- workerのasset `read`は、overlayに無い場合、この共有cacheを経由する。cache hitでも
  各workerへのbinary responseは従来どおり返すため、IPC protocolとworker capabilityの
  要件は変更しない。
- cacheは`Workspace`の寿命に閉じ込め、commit後に明示的にclearする。次のwatch buildは
  新しい`Workspace`で開始する。
- `FAST_BUILD_RUNNER_METRICS=1`ではcache hit/missを`Rust workspace metrics`として
  出力し、worker数を増やした場合のfilesystem read重複をwall timeと併記して評価する。
- cache fill競合時は既に格納されたbytesを再利用する。ただし異なるassetのfilesystem
  readを一つの大域ロックで直列化しない。same-assetの同時missを完全に一回へ畳み込む
  per-key in-flight機構は、計測で必要性が確認されるまで導入しない。

## Measurement snapshot

2026-09-04、同じbenchmark scriptで`FAST_BUILD_RUNNER_METRICS=1`を有効にして測定した。
単回値なのでwall timeの差は参考値とし、cache hit/missを主な判断材料にする。

| fixture / case | jobs | Rust wall | read requests | cache hits | cache misses |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100入力 / 全入力変更 | 1 | 4.522 s | 313 | 12 | 225 |
| 100入力 / 全入力変更 | 2 | 3.297 s | 326 | 25 | 225 |
| 500入力 / 全入力変更 | 2 | 7.736 s | 1,526 | 25 | 1,025 |

いずれも生成物は`byte-identical=yes`で、Rust no-opもpassした。`jobs=2`ではworkerごとの
Dart-side cacheが分離されるためread RPC自体は増えるが、Rust側では同じbuild中の一部
assetを共有できた。500入力の`jobs=2`について、ADR-0036の前回値8.030 sに対して今回
7.736 sだったが、単回測定の揺らぎを含むためcache単独の改善率とは扱わない。

## Consequences

- `jobs=2`以上でも、同一build中に同じassetをfilesystemから読み出す回数を減らせる。
- workerごとのreset-scoped Dart cacheと役割が異なるため、既存のDart-side cache、
  dependency tracking、strict binary IPCを変更せずに済む。
- response frame数とresponse bytes自体は減らない。次にIPC round-tripを削減する場合は、
  builderの動的read semanticsを壊さないbatch APIとして別ADRを作る。
- cache保持分のメモリをbuild中に消費する。現在は全体を保持する単純な実装とし、必要なら
  metricsにpeak bytesを追加して上限やevictionを別途判断する。

## Alternatives considered

- Dart worker間でcacheを共有する: worker process境界を越える共有が必要で、lifecycleと
  analyzer stateの分離を複雑にするため採用しない。
- asset RPCを先読み・batch化する: `read`と`canRead`はbuilderの動的実行中に発生するため、
  speculative prefetchは意味を変えるリスクがある。round-trip削減の効果を別計測してから
  protocol拡張として判断する。
- cacheをwatch iteration間で再利用する: 外部変更を古いbytesで隠す可能性があるため採用しない。
- same-assetのmissを大域Mutex保持中にfilesystem readして完全にdeduplicateする: 異なる
  assetのparallel readまで直列化するため、まず非直列の簡素な実装を採用する。
