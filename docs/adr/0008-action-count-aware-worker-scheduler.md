# ADR-0008: phaseのaction数に応じてworkerを遅延起動・縮小する

- Status: Accepted
- Date: 2026-09-03

## Context

`--jobs N`を常にN processへ展開すると、1 actionのincremental buildでもDart SDKとAnalyzerを複数起動する。一方、全入力変更時には1 workerだけでは独立actionを並列化できない。

## Decision

- `--jobs`の既定値は1とし、並列実行はopt-inにする。
- phaseごとに対象action数を数え、worker数を`min(max_jobs, action_count)`へ合わせる。
- WorkerPoolは最初に1 workerだけ起動し、action数が増えたphaseの直前に不足分を遅延起動する。
- action数が減った場合は余剰workerを終了し、次のwatch buildでは必要数まで再利用・再起動する。
- worker 1個の場合は`build_batch`、複数workerの場合はworker数ごとのwaveで実行する。
- correctnessとbyte identityを性能より優先し、parallelismは実験的機能として扱う。

## Consequences

- 小さなincremental buildで不要なworker起動を避けられる。
- 大きなphaseではwall time短縮の余地があるが、CPU、RSS、IPCの総量は増え得る。
- worker数の違いでBuilderの共有状態に依存しないことが必要になる。
- ベンチマークはclean、1-file、全入力変更、no-opを分け、wall timeだけでなくCPU/RSSも確認する。

## Alternatives considered

- 常に`--jobs`個のworkerを起動する: schedulerは単純だが、小さな差分に不利。
- 全actionを単一workerのbatchにする: 起動数は少ないが、全入力変更時の並列性を失う。
- 自動で最適jobsを推測する: hardware、Analyzer負荷、fixture規模に依存するため、PoCでは明示opt-inを選ぶ。

