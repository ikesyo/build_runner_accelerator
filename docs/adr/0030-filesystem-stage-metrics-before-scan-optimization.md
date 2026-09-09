# ADR-0030: filesystem stage metricsをscan最適化より先に追加する

- Status: Accepted
- Date: 2026-09-04

## Context

Rust frontendは、毎回のroot snapshot scan、追跡済みgenerated/dependency/globの追加、
output digest、build後の再scanを行う。外側のwall timeだけでは、filesystem、glob照合、
worker、graph persistenceの寄与を分離できず、変更の正しさを保ったまま性能判断する
ことが難しい。

## Decision

- `FAST_BUILD_RUNNER_METRICS=1`のとき、stderrへ`Rust filesystem metrics:`を出力する。
- 初回root scanの時間・asset数・byte数、generated/dependency/glob追加、dirty判定、
  build後scan、build後asset追加をbuild単位で測る。
- metricsは既存のgraph/worker metricsと同じopt-in・stderr-only経路に置き、通常実行の
  protocol、stdout、生成物、計測負荷を変えない。
- scanやdigestの意味を変える最適化は、このstage計測で支配コストを確認してから導入する。

## Consequences

- no-opを含めて、filesystemとglob処理の寄与をworker/graphと分離して比較できる。
- stderrに追加の1行が出るため、metricsを解析する利用側は新しい項目を扱う必要がある。
- 時間計測だけではsyscall単位のread/open内訳は分からないため、必要時は既存の
  `IO_METRICS=1`と組み合わせる。

## Alternatives considered

- wall timeだけでscan最適化を選ぶ: worker起動やDart処理と混ざり、原因と効果を誤認しやすいため採用しない。
- 常時metricsを有効にする: 通常benchmarkと実運用のstderrおよびoverheadを変えるため採用しない。
- protocol messageへmetricsを追加する: IPC schemaとbuilder責務を汚すため採用しない。
