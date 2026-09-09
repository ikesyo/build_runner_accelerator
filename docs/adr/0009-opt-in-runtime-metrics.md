# ADR-0009: runtime metricsはstderr-onlyのopt-inにする

- Status: Accepted
- Date: 2026-09-03

## Context

次段階の最適化には、workerの起動・reset状況、IPC往復、asset RPC、read bytesをbuild単位とwatch session単位で観測する必要がある。通常実行のstdoutやprotocol payloadに診断情報を混ぜると、既存のframe parserや生成物比較を壊し、常時計測のserialization overheadも増える。

## Decision

- `BUILD_RUNNER_ACCELERATOR_METRICS=1`のときだけRust frontendがstderrへ1行のmetricsを出力する。
- 出力はworker lifecycle、IPC frame数/bytes、asset request数、`read` request数とpayload bytes、`can_read`、`find_assets`のquery/result数を含める。
- IPC bytesはRust-Dart間のframe（4-byte length prefixを含む）の累積値とする。`read_bytes`はRustがasset responseとして返したpayload bytesであり、OS syscallのread bytesとは区別する。
- watch sessionではmetricsを累積し、workerの縮小で終了したworkerの値も保持する。
- protocol schemaを変更せず、stdoutとbuild resultにはmetricsを追加しない。OSレベルのI/Oは既存の`IO_METRICS=1`計測を使う。

## Consequences

- 通常実行の互換性と出力を変えずに、schedulerとIPCのボトルネックを比較できる。
- 数値はprocess/session内の累積値なので、clean/no-op/1-file/全入力変更を別々に測る必要がある。
- `read_bytes`はfilesystemが実際に発行したsyscall bytesではない。OS I/Oの判断には別計測が必要である。
- metricsを有効にした実行ではstderrログの解析が必要になり、ログ形式は将来の変更対象になり得る。

## Alternatives considered

- build resultへmetrics fieldを追加する: protocol互換性とgraphの責務を汚すため採用しない。
- 常時metricsを計測する: overheadは小さくても、PoCの通常測定を変えるため採用しない。
- Rustの外側だけでstraceを使う: OS I/Oは取れるが、worker lifecycleやasset RPCの意味単位を区別できない。

