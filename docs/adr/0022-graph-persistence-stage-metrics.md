# ADR-0022: graph persistenceのstage metricsをopt-inで出力する

- Status: Accepted
- Date: 2026-09-04

## Context

AssetGraphをindexed/lazy storeへ進める前に、現在の全体decodeと全体saveがclean、
no-op、incremental buildのどこで時間を使っているかを分離して測る必要がある。
外側のwall timeだけでは、filesystem scan、Dart worker、graph codec、process起動の
寄与を区別できない。

## Decision

- `FAST_BUILD_RUNNER_METRICS=1`のとき、buildごとにstderrへ`Rust graph metrics:`を出力する。
- `load_us`はgraph fileのreadとbinary decode、`save_us`はencode、一時fileへのwrite、
  renameを含む経過時間として測る。
- `load_bytes`と`save_bytes`はgraph fileのsize、`save_skipped`は変更のないno-opで
  保存を省略したかを示す。saveを行わない場合は`save_us=0`とする。
- metricsはstdout、生成物、IPC protocol、GraphStateの意味を変更しない。既存の
  `FAST_BUILD_RUNNER_METRICS` worker metricsと同じstderr-onlyの観測経路を使う。
- process startupやsnapshot scanなどstage外の時間は、既存benchmarkのwall/user/sysと
  組み合わせて判断する。

## Measurement snapshot

2026-09-04に、追跡済みの100入力fixtureを新規生成し、`COUNT=100 JOBS=1`で次を
実行した。

```bash
FAST_BUILD_RUNNER_METRICS=1 COUNT=100 JOBS=1 \
  bash scripts/benchmark_json_serializable.sh
```

| ケース | graph load / save | graph bytes (load → save) | Rust frontend wall |
| --- | ---: | ---: | ---: |
| clean | 5 / 1,063 µs | 0 → 147,895 | 8.506 s |
| no-op | 1,341 / 0 µs | 147,895 → 147,895 | 0.407 s |
| 1-file | 1,125 / 994 µs | 147,895 → 147,895 | 2.510 s |
| all-file (100入力、200 actions) | 1,259 / 1,615 µs | 147,895 → 147,895 | 5.545 s |

全ケースで`byte-identical=yes`かつ`no-op=yes`だった。cleanではgraphが存在しないため
load bytesは0であり、no-opでは`save_skipped=true`になった。値は単回測定であり、実行環境
固有の参考値として扱う。

## Consequences

- codecとfilesystem writeの実測値を、no-opを含むbuild単位で比較できる。
- metrics有効時はstderrに1行追加され、ログ解析側はその形式を扱う必要がある。
- `load_us`/`save_us`はOS syscallの内訳ではない。必要な場合は既存の`IO_METRICS=1`を
  併用する。
- indexed/lazy storeへの移行判断を、graph file sizeだけでなくstage時間に基づいて行える。

## Alternatives considered

- 外側の`time`だけを使う: process起動、scan、worker、graphの寄与を分離できないため採用しない。
- 常時stage metricsを出す: 通常benchmarkのstderrと計測 overheadを変えるため採用しない。
- graph codec内でglobal metricsを持つ: watch sessionやno-opのsave skipを呼び出し側で正しく
  表現しにくく、stderr出力責務も混ざるため採用しない。
