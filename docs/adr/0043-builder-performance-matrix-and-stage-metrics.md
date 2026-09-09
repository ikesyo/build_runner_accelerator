# ADR-0043: builder横断性能マトリクスとworker stage metrics

## Status

Accepted

## Context

Freezed、`json_serializable`、`riverpod_generator`の対応で、個別builderのclean・no-op・
incremental・failure・watchは検証できるようになった。一方、各benchmarkのfixtureと出力が
異なるため、builder間の比較を同じ軸で追跡しにくかった。また、1-file incrementalのwall timeが
worker起動、resolver初期化、asset RPC、builder実行のどこに支配されるかを、既存の件数metrics
だけでは切り分けられなかった。

## Decision

- `scripts/benchmark_matrix.sh`を追加し、対応中の3 builderを同じ`JOBS`条件で順番に計測する。
  各builder固有のbenchmarkは引き続き独立して実行でき、matrix scriptはtiming行とruntime
  metricsを集約表示する。
- `riverpod_app`に`secondary.dart`を追加し、Riverpod単独入力とFreezed・JSON併用入力を
  同じpackageで持つ。これによりRiverpodにも1-fileとbroad incrementalの比較軸を持たせる。
- `BUILD_RUNNER_ACCELERATOR_METRICS=1`の`Rust metrics:`へ、次の時間とreset数を追加する。
  - worker process start
  - worker initialize（Analyzer resolver初期化を含む）
  - resident worker reset
  - resolver-only reset
  - builder build / build batch
  - asset RPC応答
- 既存のIPC frame・asset request・filesystem・graph・workspace metricsは維持する。新しい
  metricsはstderrだけに出し、protocol payload、生成物、通常のstdoutを変更しない。
- `--jobs`の既定値とgraph/cache方式は、このマトリクスの測定だけを根拠に変更しない。特に
  1-file incrementalの支配要因が確定するまでは、既定worker数1を維持する。

## Verification

同じDart SDK、Pub cache、Rust binary、`JOBS=1`で測定した。生成物は各ケースでstockと比較し、
Rust側のno-opとRiverpodのfailure rollbackも確認した。

| Builder / case | stock real | Rust real |
| --- | ---: | ---: |
| `json_serializable` 10入力 / clean | 2.778s | 2.059s |
| `json_serializable` 10入力 / no-op | 1.675s | 0.007s |
| `json_serializable` 10入力 / 1-file | 2.586s | 1.916s |
| `json_serializable` 10入力 / broad | 2.743s | 2.248s |
| `freezed` / clean | 16.454s | 10.589s |
| `freezed` / no-op | 1.650s | 0.010s |
| `freezed` / 1-file | 2.990s | 2.503s |
| `freezed` / broad | 3.316s | 2.902s |
| `riverpod` / clean | 17.832s | 12.203s |
| `riverpod` / no-op | 1.652s | 0.021s |
| `riverpod` / 1-file | 4.554s | 4.958s |
| `riverpod` / broad | 4.937s | 5.142s |

上記は各1回の参考値で、GNU `time`のmax RSSは取得できなかった。全ケースで出力は
byte-identical、no-opはRust側でworkなし、Riverpodはsecondary入力を含む4ケースでpassした。
`benchmark_matrix.sh`は同じケースを継続的に採取する入口であり、追加した時間metricsで
1-fileの支配要因を確定する作業は次の反復測定に残す。

## Alternatives considered

- builderごとのbenchmark出力を手作業で比較する: 既存スクリプトを保てるが、case名と
  metricsの抜け漏れを検出しにくいため採用しない。
- `--jobs 2`を既定値に変更する: cleanやbroadで有利なケースがあっても、no-op・1-fileの
  worker起動やread重複の影響を同時に評価できるまでは変更しない。
- workerを毎回再起動してresolver初期化時間を測る: watchのresident worker lifecycleと
  異なるため、通常のbuildで観測されるinitialize/resetを計測する。
