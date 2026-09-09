# ADR-0035: 検証ループではRust frontendバイナリを再利用する

- Status: Accepted
- Date: 2026-09-04

## Context

`verify.sh`のcorrectness caseは、各caseを一時workspaceへ隔離し、stock
`build_runner`とRust frontendを複数回起動する。Rust側の各起動を`cargo run`にすると、
同じ検証ループの中でCargoのtarget確認と実行ラッパー起動を繰り返す。これは生成物の
比較条件やcorrectnessの意味には不要なオーバーヘッドである。

一方、correctness caseを並列化するとstock/Rust比較の再現性を損なうことが既に分かって
いるため（ADR-0012）、実行バイナリの共有だけを行い、caseの直列性とworkspace隔離は
変更しない。

## Decision

- `verify.sh`は開始時にRust frontendを一度だけ`cargo build`し、生成された
  `BUILD_RUNNER_ACCELERATOR_BIN`を子scriptへ継承する。
- `scripts/run_rust_frontend.sh`は`BUILD_RUNNER_ACCELERATOR_BIN`が指定されていればその実行
  ファイルを直接起動し、未指定の単独実行では従来どおり`cargo run`を使う。
- `smoke.sh`、`watch_smoke.sh`、`correctness_json_serializable.sh`、
  `benchmark_json_serializable.sh`も、事前ビルド済みバイナリを受け取った場合は直接起動する。
- バイナリのビルド・Rust unit test・Dart analyze・stock/Rust byte比較は省略しない。

## Consequences

- 1回の検証入口でCargoによるRust実行の準備を繰り返さずに済む。
- `BUILD_RUNNER_ACCELERATOR_BIN`を明示すれば、複数のbenchmarkまたはcorrectness実行でも同じ
  ソースから作ったバイナリを再利用できる。
- `verify.sh`の単回測定では、対象2ケースが`56.8s`から`56.0s`となった。差は約1.4%で、
  このfixtureではDart/Analyzer起動が支配的であることも確認できた。したがって、この変更を
  Rust runtime自身の高速化とは扱わない。
- 事前ビルド済みバイナリを使う場合、呼び出し側がそのバイナリを現在のsourceから生成
  したことを保証する必要がある。`verify.sh`は自分でbuildするため、この条件を満たす。

## Alternatives considered

- 各Rust実行を常に`cargo run`にする: 単独scriptは簡単だが、反復検証で準備処理を繰り返すため採用しない。
- correctness caseを並列実行してwall timeを下げる: ADR-0012で確認した非決定性を再導入するため採用しない。
- Rust unit testまたはstock比較を省略する: ループは短くなるが、品質ゲートを弱めるため採用しない。
