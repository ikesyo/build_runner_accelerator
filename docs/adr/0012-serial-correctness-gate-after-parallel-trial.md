# ADR-0012: correctness gateは逐次実行へ戻す

- Status: Accepted
- Date: 2026-09-03

## Context

ADR-0010で、独立temp fixtureを使うcorrectness caseを別processで並列実行し、長い検証時間を短縮する案を採用した。しかし実測では、package名をcaseごとに一意化しても、`input-delete`や`rename`のstock/Rust比較が並列時だけ不安定になった。各caseを同じ条件で逐次実行すると再現せずpassした。

これは生成物比較のrelease gateに非決定性を持ち込むため、速度向上より検証の信頼性を優先する必要がある。

## Decision

- `scripts/verify.sh`のtargeted/full correctness caseは逐次実行する。
- `VERIFY_CASES`による対象絞り込みは維持し、開発中は必要なcaseだけを実行して総時間を短縮する。
- correctness processの安全な並列化は未解決課題とし、precompiled worker、PUB cache/process isolationなどを含む別実験として扱う。
- ADR-0010のtier分割は維持するが、correctness caseの並列実行という部分はこのADRで置き換える。

## Consequences

- full correctnessのwall time短縮は失うが、stock/Rustのbyte比較と削除・rename判定を安定した条件で実行できる。
- quickとtargetedのcase選択により、毎回全10ケースを回す必要はない。
- 並列化を再開する場合は、同じcaseを逐次baselineと比較し、複数回連続passしてからrelease gateへ昇格させる。

## Alternatives considered

- 並列実行を既定のまま残す: 一時的な高速化と引き換えに、再現性のないfalse failureを許容するため採用しない。
- `VERIFY_JOBS=1`を既定にし、値2以上を黙って許可する: 安全な既定は得られるが、release gateで誤って不安定モードを使う余地が残る。
