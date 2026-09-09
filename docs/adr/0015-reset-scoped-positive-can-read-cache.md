# ADR-0015: reset区間に限定したpositive `canRead` cacheを使う

- Status: Accepted
- Date: 2026-09-03

## Context

ADR-0011で、同じDart workerのaction間にasset bytesのread cacheを共有した。
しかし`AssetReader.canRead`は同じassetに対して別途RPCを発行するため、100入力の
fixtureでは、bytes readを増やさずに存在確認だけが繰り返されていた。

一方、`canRead=false`をcacheすると、先行actionがまだ生成していないassetを後続
actionがoverlayへ追加した場合に、同じreset区間の後続判定が古いmissing結果を
使う危険がある。workerはphase間でRust overlayを参照するため、missing結果の
cacheはincremental correctnessと相性が悪い。

## Decision

- `_WorkerRuntime`が`AssetId`のpositive `canRead`結果をreset区間だけ保持する。
- `canRead=true`だけをcacheし、`false`またはerrorはcacheしない。
- `RemoteAssetReaderWriter.canRead`では、当該actionの`outputs`、read bytes cache、
  positive `canRead` cacheの順に確認してからRPCを発行する。
- `initialize`と`reset`の両方でpositive cacheをclearする。
- worker process間ではcacheを共有しない。overlayの新しいoutputはcacheより常に
  優先する。

## Consequences

- 同じworkerのaction間で、既に存在が確認できたassetの`can_read` RPCとIPC frameを
  減らせる。
- read bytesと生成物のbyte identityは変更しない。
- missing assetが後続phaseで生成される場合でも、negative cacheがそれを隠さない。
- positive resultをresetまで保持するため、workerごとのメモリ使用量はわずかに増え得る。
- `jobs>1`ではworkerごとにcacheが分かれるため、削減効果はworker数に依存する。

## Measurement snapshot

100入力、`jobs=1`、runtime metrics有効のbenchmarkで、ADR-0011のbytes read cache
のみの場合と比較した。wall timeは単回測定の揺らぎが大きいため、この判断ではRPC
削減を評価した。

| metric | positive cache前 | positive cache後 |
| --- | ---: | ---: |
| IPC frames | 930 | 729 |
| asset requests | 927 | 726 |
| `can_read` requests | 514 | 313 |
| `read` requests | 313 | 313 |
| `read_bytes` | 183,658 | 183,658 |

10入力でも、IPC framesは120から99、`can_read` requestsは64から43へ減少した。
いずれも`read` requestsと`read_bytes`は変わらなかった。生成物のbyte identity、
no-op、correctness全10ケースは別途確認する。

## Alternatives considered

- `canRead=false`もcacheする: RPCはさらに減るが、後続phaseのoverlay生成を古い
  missing結果で隠すため採用しない。
- `canRead` cacheをwatch session全体で保持する: RPCは減るが、filesystem変更後の
  可視性をreset境界で保証できないため採用しない。
- Rust側で存在判定を一括送信する: protocol変更と不要なasset列挙が発生するため、
  現段階では既存RPCへの局所的なcacheを優先する。
