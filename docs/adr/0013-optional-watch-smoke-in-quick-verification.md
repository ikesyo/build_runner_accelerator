# ADR-0013: quick verificationのwatch smokeをopt-inにする

- Status: Accepted
- Date: 2026-09-03

## Context

native watch smokeはworker再利用・generated output削除・source editを確認できる重要なテストだが、常駐processの起動とイベント待ちがあり、通常のbuild/graph変更確認より遅い。毎回watchを起動すると、開発ループ全体の短縮効果を弱める。

## Decision

- `scripts/verify.sh`のquick levelはDart analyze、smoke、Rust unit/format、byte identity/no-opに限定する。
- watch smokeは`VERIFY_WATCH=1`で追加する。
- full levelは`VERIFY_WATCH=1`相当でquickを実行し、watchもrelease gateへ含める。

## Consequences

- 通常のquick確認を短くできる。
- watch lifecycleの変更時はtargetedまたはfullで`VERIFY_WATCH=1`を明示する必要がある。
- watch検証を省略したquick passを、watch機能のrelease判断には使わない。

## Alternatives considered

- 常にwatch smokeをquickへ含める: watch回帰は早く見つかるが、通常の変更確認が不必要に長くなる。
- watch smokeを廃止する: 速くなるが、native eventとworker再利用の回帰を検出できない。
