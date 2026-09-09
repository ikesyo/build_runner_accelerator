# ADR-0014: benchmark結果に基づきworker parallelismの既定値を決める

- Status: Accepted
- Date: 2026-09-03

## Context

Rust frontendは`--jobs N`で複数Dart workerを起動できる。worker数を増やすと独立actionを並列化できる一方、各workerが独自にAnalyzer stateとreset-scoped read cacheを持つため、RSS、CPU、IPC、asset read bytesが増える。小規模incremental buildと大規模clean buildで最適な値が同じとは限らない。

比較条件を揃えるため、stock `build_runner`とRust frontendを同じfixtureで実行し、生成物のbyte identityとRust no-opを確認した。値は各ケース1回のwall/user/sys測定であり、環境依存の絶対値ではなく傾向比較として扱う。

## Decision

- `--jobs`の既定値は1のままにする。
- 100入力程度のcleanまたは全入力変更を調べるときは、`--jobs 2`を有力な比較対象とする。ただし既定値へ昇格させず、benchmarkでfixtureごとに確認する。
- `--jobs 4`は測定専用の実験値とし、通常の推奨値にはしない。
- correctness gateはADR-0012どおり逐次実行し、worker parallelismの性能測定と互換性検証を分離する。
- 次の性能調査は、100入力の全変更で多かったasset RPC（`asset_requests=927`、IPC frame=930）を対象に、asset request batchingまたはbinary side channelの効果を測る。AssetGraphのserialization/indexed storeは、その後にstage計測で優先度を再評価する。

## Measurement snapshot

fixtureごとに同じbenchmark scriptを実行した。単位は秒、`—`は未測定である。

| case | stock | Rust `jobs=1` | Rust `jobs=2` | Rust `jobs=4` |
| --- | ---: | ---: | ---: | ---: |
| 10 clean | 3.758 | 4.037 | 2.503 | — |
| 10 no-op | — | 0.036 | 0.031 | — |
| 10 1-file | 2.686 | 2.443 | 2.054 | — |
| 10 all-file | 2.743 | 2.558 | 2.511 | — |
| 100 clean | 18.271 | 8.794 | 6.177 | 5.809 |
| 100 1-file | 2.654 | 2.658 | 2.652 | 2.684 |
| 100 all-file | 5.093 | 5.627 | 4.962 | 5.249 |

100入力のRust metricsは次の通りだった。

| jobs | IPC frames | asset requests | read requests | read bytes |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 930 | 927 | 313 | 183,658 |
| 2 | 1,156 | 954 | 326 | 229,616 |
| 4 | 1,212 | 1,008 | 352 | 321,532 |

`jobs=2`は100入力cleanで`jobs=1`よりwall timeが短く、全変更でも改善した。一方、1-file/no-opでは差が小さい。`jobs=4`は全変更で`jobs=2`より遅く、user/sys timeとread bytesが大きく増えた。したがって、既定値を2以上へ変更する根拠は不足している。

この環境ではGNU `time`がなくpeak RSSは取得できず、ptrace制限により`IO_METRICS=1`のOS syscall read/open数も取得できなかった。今後の比較では、これらが取れる環境で再測定する。

## Consequences

- 小規模なincremental/no-op buildで不要なworker、Analyzer state、asset readを増やさない。
- 大規模clean/全変更では利用者が`--jobs 2`を明示すればwall time短縮を試せる。
- `jobs>1`ではworkerごとにcacheが分かれるため、IPC/read bytesとCPU/RSSの増加を必ず併記する。
- parallel correctness gateを性能値だけで再導入しない。正しさの安定性は別の検証条件である。

## Alternatives considered

- 常に`--jobs 2`を既定にする: 大規模cleanには有効だが、no-op/1-fileの起動・cache重複コストを全buildへ課すため採用しない。
- `--jobs 4`を既定にする: 一部cleanのwall timeは下がるが、CPU、sys time、IPC/read重複が増え、全変更では`jobs=2`を下回るため採用しない。
- 常に`--jobs 1`へ固定する: 安定性は高いが、大規模clean/全変更の測定可能な並列性を失うため、明示的なopt-inは残す。
