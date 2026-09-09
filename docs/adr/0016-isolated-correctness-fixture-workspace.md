# ADR-0016: correctness fixtureを同期対象外の一時workspaceで実行する

- Status: Accepted
- Date: 2026-09-03

## Context

correctness caseはstock `build_runner`とRust frontendを別rootで実行し、生成物の
byte identityと削除・renameの挙動を比較する。fixtureをリポジトリのscratch tree
配下に作ると、workspace同期処理がbuild_runnerの削除後に旧生成物を再配置することが
あり、stockの挙動ではないfalse failureを起こす。

また、stock側とRust側が同じ一時package nameを共有すると、side-by-side実行時に
package identityの切り分けが難しくなる。

## Decision

- `scripts/correctness_json_serializable.sh`は、各実行ごとにsystem temp配下の専用
  workspaceを作る。
- workspace内に`fixtures/`階層と`dart_worker`へのsymlinkを作り、fixtureの相対path
  dependencyを維持する。
- stock rootとRust rootには`..._stock` / `..._rust`の別package nameを付ける。
- caseは引き続き逐次実行し、終了時にその実行で作ったworkspaceだけを削除する。

## Consequences

- generated outputの削除・rename assertionがworkspace同期の再配置に影響されない。
- fixtureの相対path dependencyを本番repoの構成と同じ形で検証できる。
- temp workspaceの作成と`pub get`のため、各caseの準備コストは残る。
- stock/Rustのpackage nameが異なるため、package nameを出力に埋め込むbuilderを対象に
  する場合は、そのbuilder固有のbyte identity条件を別途確認する必要がある。

## Alternatives considered

- scratch tree配下で実行し、生成物削除後に待機する: 同期処理のタイミングに依存し、
  false failureを完全には防げないため採用しない。
- fixtureを共有し、stockとRustを順番に同じrootで実行する: 一方のgraph/cacheが
  他方の判定へ混入するため、比較の独立性を失う。
- correctness caseを並列実行する: ADR-0012のとおり、速度より安定したrelease gateを
  優先するため採用しない。
