# ADR-0011: reset区間に限定したworker内asset read cacheを使う

- Status: Accepted
- Date: 2026-09-03

## Context

同じDart workerで複数actionを順番に実行しても、従来のread cacheは`RemoteAssetReaderWriter`ごとに作られていた。そのため、複数の入力が同じpackage sourceやAnalyzer依存を読むと、同一build内で同じassetをIPC越しに繰り返し取得する。常駐workerの再利用による初期化削減を、asset RPC削減にも広げたい。

一方、cacheをbuild間で無条件に保持すると、watch中のsource変更を古いbytesで読む危険がある。phase間ではRust overlayの新しいoutputを優先しなければならない。

## Decision

- `_WorkerRuntime`が`AssetId`からbytesへのcacheを所有し、同じworkerのaction間で共有する。
- `initialize`と`reset`の両方でcacheをclearする。したがってcacheの有効期間は、workerのresetから次のresetまでに限定する。
- `RemoteAssetReaderWriter`は共有cacheを参照する。`outputs`は共有read cacheより常に先に確認し、当該buildのoverlay outputを優先する。
- missing/error responseはcacheしない。
- worker process間ではcacheを共有しない。並列workerのcache重複は、正しさと実装単純性を優先して許容する。

## Consequences

- 同じworkerの複数actionで共通assetを再取得するIPCとJSON bytes転送を減らせる。
- 一度読んだbytesをresetまで保持するため、workerごとのRSSは増え得る。
- watchのbuild開始時にclearするため、変更後のfilesystemを古いcacheが隠すことはない。
- parallelismを有効にするとworkerごとにcacheが分かれるため、read削減効果はjobs=1より小さくなり得る。
- cacheの有効性は「build中に外部からassetが変更されない」ことを前提とする。filesystem eventを受けた次のbuildではresetで破棄する。

## Initial measurement

10入力・20 actions・`jobs=1`の同一fixtureで、cache追加前後を各1回測定した。環境依存のため絶対値ではなく、削減箇所の確認として扱う。

| metric | before | after |
| --- | ---: | ---: |
| IPC frames | 140 | 120 |
| asset requests | 137 | 117 |
| `can_read` requests | 84 | 64 |
| `read` requests | 43 | 43 |
| `read_bytes` | 59,497 | 59,497 |

このfixtureでは共通の存在確認が主な削減対象で、実bytes readは増減しなかった。今後は、より共通依存が多いfixtureと`jobs>1`で効果を再測定する。

## Alternatives considered

- actionごとのcacheを維持する: 実装は最小だが、複数actionの共通依存に対するIPC削減効果を失う。
- cacheをwatch session全体で保持する: read RPCはさらに減るが、変更無効化の粒度と正しさの検証が難しくなる。
- Rust側から全assetを事前送信する: RPCは減るが、不要assetの転送とprotocol拡張が発生する。
