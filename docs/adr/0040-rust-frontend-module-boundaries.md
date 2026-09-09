# ADR-0040: Rust frontend の責務別module分割

- Status: Accepted
- Date: 2026-09-04

## Context

`rust/src/main.rs`は、CLI、frontend選択、builder catalog、action planning、graphの
lifecycle、watch、metrics、atomic commitを同時に持つ1,347行のファイルになっていた。
この状態では、次の`freezed`や`riverpod_generator`対応で責務の境界が見えにくくなり、
builder固有処理を再びentrypointへ追加するリスクがある。

一方、今回の目的は構造改善であり、filesystem scan、digest、graph、overlay、worker
IPC、phase orderingなどの実行アルゴリズムやデータ構造を変更することではない。
module分割による性能回帰を避けるため、hot pathに新しいdynamic dispatchや不要な
中間データを導入しない必要がある。

## Decision

- `main.rs`はmodule宣言とCLI command dispatchだけを担当する。
- `cli.rs`は`Options`と`FrontendMode`を担当する。
- `builder.rs`はbuilder definition catalog、`build.yaml`対応subset、builder設定を
  担当する。
- `frontend.rs`はRust/Dart frontendの選択とDart fallbackを担当する。
- `plan.rs`はinput候補、`BuildSpec`、action key、output mappingを担当する。
- `build.rs`はsnapshotからのdirty判定、phase実行、overlay、全成功後commit、graph
  更新を担当する。
- `assets.rs`はgenerated/dependency/glob assetのsnapshot追加、config digest、atomic
  output writeを担当する。
- `watch.rs`はfilesystem event、debounce、worker再利用を担当する。
- `metrics.rs`はopt-in runtime metricsの集計・出力を担当する。
- module間で共有する型・関数だけを`pub(crate)`にし、既存の`BTreeMap`/`BTreeSet`、
  `Vec`、overlay、batch IPCのデータフローは維持する。
- module境界は静的なRust関数呼び出しとし、trait object、dynamic dispatch、追加の
  serializationを導入しない。したがって、分割自体による実行時オーバーヘッドを
  発生させない。

## Consequences

- `main.rs`は34行になり、builder対応・実行・watch・計測の責務を個別に変更できる。
- `freezed`と`riverpod_generator`はbuilder catalog / parser / plan / worker fixtureの
  境界へ追加でき、entrypointの特別分岐を増やさずに済む。
- module分割だけではalgorithmicな性能改善は発生しないが、既存の性能特性を保った
  まま検証可能な構造になる。
- 既存のRust unit test、stock比較、correctness、watch、benchmarkを回帰ゲートとして
  維持する。

## Alternatives considered

- `main.rs`に全処理を残す: 小規模な間は単純だが、builder追加と性能計測の責務が混在
  し続けるため採用しない。
- すべてを細かいtraitへ抽象化する: テスト容易性は上がる可能性があるが、今回の目的に
  対してdynamic dispatchと実装複雑性を導入するため採用しない。
- filesystemやschedulerを今回さらに分割する: 将来の性能最適化時に検討するが、今回
  は既存module（`workspace`、`snapshot`、`worker`、`graph`）との責務重複を避ける。
