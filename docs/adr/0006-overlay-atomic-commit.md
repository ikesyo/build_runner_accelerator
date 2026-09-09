# ADR-0006: overlay と全成功後の atomic commit を採用する

- Status: Accepted
- Date: 2026-09-03

## Context

phase 1のcombining builderはphase 0のcache outputを読む。途中でsourceやcacheへ書き込むと、後続actionからは見えるが、途中失敗時に一部だけ新しい成果物やgraphが残る。生成物の破損より、再実行可能な前回状態の保持を優先する必要がある。

## Decision

- 成功したworker outputは、commit前にRustのoverlayへ置く。
- 後続phaseのasset readはoverlay、既存filesystem、cacheの順で解決する。
- 全dirty actionが成功し、期待外outputがないことを検証した後に、outputを一時ファイル経由でatomic renameする。
- outputのcommitとgraph stateの保存は成功したbuildの最後に行う。
- 失敗したbuildは、前回committed outputとgraphを保持する。

## Consequences

- phase間の生成物可視性と、失敗時のrollback安全性を両立できる。
- 成功outputのbytesをcommitまでメモリに保持するため、大きな生成物ではmemory pressureが増える。
- output削除は、削除対象actionを確定した後のcommit段階で行う。

## Alternatives considered

- action成功ごとに即時書き込みする: 実装は単純だが、後続失敗時に中間状態が残る。
- 全outputを別directoryへ書いてdirectory swapする: 強いcommit単位を作れるが、既存のcache/source pathとの統合が大きい。

