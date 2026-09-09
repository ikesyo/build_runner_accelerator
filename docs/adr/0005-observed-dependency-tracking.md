# ADR-0005: observed dependency をresolverとglobまで拡張する

- Status: Accepted
- Date: 2026-09-03

## Context

Builderの直接readだけでは、Analyzerが解決候補として調べたconditional import/exportや、`findAssets`の結果集合の変更を検出できない。特に、前回は存在しなかった候補やglobの空集合への追加を見落とすと、incremental結果が古くなる。

## Decision

- workerは通常のasset readを`reads`として返す。
- Resolverが観測した候補を`resolver_reads`として返し、現在選択されていない候補や存在しない候補も記録する。
- `findAssets`のpackageとpatternを`glob_reads`として返す。
- Rustはglobのsorted matching asset setと各content digestから依存digestを作り、追加・削除・内容変更でactionをdirtyにする。
- 保守性を優先し、conditional import/exportの全候補を記録する。選択されない候補の変更による余分な再実行は許容する。

## Consequences

- 依存追加、削除、conditional candidate追加、glob対象追加をincremental判定へ反映できる。
- 依存探索のためのfilesystem readとstateサイズが増える。
- 全候補記録により、最小のdirty集合より広く再実行するケースがある。

## Alternatives considered

- 実際に選択されたresolver URIだけを記録する: 未存在候補の追加を検出できない。
- globを毎回全actionへ適用する: 正しさは保ちやすいが、action単位の影響追跡を失う。
- ResolverをRustへ移植する: Analyzer互換の範囲が大きく、worker境界の方針に反する。

