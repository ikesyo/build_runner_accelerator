# ADR-0038: 複数workerでもphase内requestをbatch化

- Status: Accepted
- Date: 2026-09-04

## Context

現在の`WorkerPool::build_parallel`は、`jobs=1`では既存の`build_batch`を使う一方、
`jobs>1`ではreadyになったrequestをworker数ごとのwaveに分け、各workerへ1 actionずつ
単発の`build`を送っていた。500入力fixtureでは、2 phase × 500 actionのため、
workerを2個にしてもbuild-resultのIPC frameがaction数に比例して増え、waveごとに
`thread::scope`も作り直していた。

このphaseのrequest列はRust側で同じphaseの実行対象として集めたready actionであり、
dependency graphの次のphaseへ進む前に全結果を受け取る。したがってphase内のrequestを
workerごとの連続sliceへ分割しても、phase順序、入力順、overlayへの反映順、全成功後の
atomic commitを変更しない。`build_batch`はDart worker内でrequestを順番に処理し、
builderの動的asset RPCとobserved dependency記録も従来どおり維持する。

## Decision

- `jobs>1`ではphase内requestをworker数でできるだけ均等な連続sliceへ分割する。
- 各sliceを1 workerの既存`build_batch`へ渡し、sliceごとの結果をworker順に連結する。
- requestがworker数未満の場合は、request数を上限にworkerを起動する既存の遅延起動を維持する。
- IPC protocol、binary build result、asset RPC、worker capability要件、JSON fallbackなしの
  方針は変更しない。
- correctnessは従来どおりstockとのbyte comparisonと逐次correctness gateで確認し、
  `jobs>1`はbenchmarkでworker数・build-result frame数・wall timeを併記して評価する。

## Measurement snapshot

2026-09-04、Dart 3.13.3、Rust 1.91.1、同一fixture、各ケース1回のローカル測定。
`maxrss`はこの環境では取得できなかった。

| fixture / case | Rust `jobs=1` | Rust `jobs=2` | byte-identical |
| --- | ---: | ---: | :---: |
| 100入力 / clean | 7.643 s | 3.282 s | yes |
| 100入力 / no-op | 0.021 s | 0.022 s | yes |
| 100入力 / 1-file | 1.925 s | 1.927 s | yes |
| 100入力 / 全入力変更 | 4.418 s | 3.588 s | yes |
| 500入力 / clean | 14.529 s | 7.719 s | yes |
| 500入力 / no-op | 0.127 s | 0.111 s | yes |
| 500入力 / 1-file | 2.120 s | 2.220 s | yes |
| 500入力 / 全入力変更 | 10.744 s | 7.714 s | yes |

500入力・全入力変更の`jobs=2`では、worker 2個、build-result binary frame 4件、
IPC送信3,558 frame、build action 1,000件だった。`jobs=1`ではbuild-result frame 2件、
IPC送信3,529 frameだった。batch化によりbuild-result frameはaction数ではなく
phase × worker数に抑えられている。

同じ`jobs=2`測定のasset metricsは、asset request 3,552、read request 1,526、
read response bytes 780,630、workspace read cache hit 25 / miss 1,025だった。
asset RPCはbuilderの動的実行境界なので、今回の変更では先読み・推測実行を行わない。

## Consequences

- 大規模なclean/全変更では、workerを増やしたときのIPC round-tripとscope生成回数を
  削減でき、今回の500入力全変更では`jobs=2`が`jobs=1`より約28%短かった。
- no-opと1-fileではworkerを増やす効果が小さく、`--jobs`既定値1の判断は維持する。
- 各worker内ではsliceを順番に処理するため、builderの実行順とasset RPC semanticsを
  変更しない。
- 1つのslice内で途中のrequestが失敗した場合も、既存のbatch resultと全成功後commitの
  safety propertyを利用できる。
- worker間のasset read cacheはbuild単位で共有する既存ADR-0037と併用されるが、
  response frameやasset RPC自体をbatch化する判断ではない。

## Alternatives considered

- 既存のwaveごとの単発`build`を維持する: 実装は単純だが、500入力ではaction数に
  比例するbuild-result frameとscope生成を残すため採用しない。
- 全requestを1つのworkerへ`build_batch`する: IPCは最小になるが、worker間のCPU並列性を
  失うため採用しない。
- asset `read` / `canRead`を先読みしてbatch化する: 動的なbuilder実行順の意味を変える
  可能性があるため、別途計測とADRが必要であり今回は採用しない。
