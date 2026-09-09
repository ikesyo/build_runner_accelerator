# ADR-0017: asset `read`成功応答を単一バイナリフレームで運ぶ

- Status: Accepted
- Date: 2026-09-03

## Context

ADR-0015のpositive `canRead` cacheで、100入力・`jobs=1`のasset RPCは
927から726、IPC frameは930から729へ減った。残った`read`は313回、payload
bytesは183,658 bytesであり、Rustが返すasset bytesをJSONの数値配列へ展開する
コストが次のIPCボトルネック候補になった。

read/canReadはbuilderの実行中に動的に発生するため、先読みのrequest batchingは
不要なassetを送る危険がある。また、単純にmetadataとraw bytesを別フレームに
分けると、RPCごとのframe数が増えてしまう。

## Decision

- Dart workerは`initialized`で`asset-rpc-binary-read-v1` capabilityを広告する。
- Rustはそのcapabilityを確認したworkerに対し、成功したasset `read`だけを
  `BRAB` magic、metadata length、metadata JSON、raw bytesからなる単一のlength-prefixed
  binary frameで返す。
- metadataには`type`、`id`、`ok`、`encoding=raw`、`length`を含め、Dart側は
  `length`と実payload長を検証してからbytesとしてBuildStepへ渡す。
- missing/error、`can_read`、`find_assets`は従来のJSON frameを使う。
- capabilityがないworkerには、従来のJSON `bytes`配列で応答する。
- `build_result.outputs[].bytes`は今回変更せず、large output対応は別の判断にする。

## Consequences

- read RPCのframe数を増やさず、JSON数値配列の展開・解析と転送量を削減できる。
- 既存workerとの組み合わせではJSON fallbackが働くため、protocol v1の段階的な
  移行余地を残せる。
- binary envelopeのparserとlength検証が増える。破損・途中切断はworkerエラーに
  できるが、raw bytesのデバッグ容易性はJSONより低い。
- `read_bytes`（実データ量）と生成物のbyte identityは変わらない。
- binary化だけではworker起動、Analyzer、filesystem scanのコストは下がらない。
  wall timeの改善はbenchmarkの反復測定で確認し、単回値から断定しない。

## Measurement and acceptance

- Dart format/analyze、Rust unit testsを通す。
- smoke、watch smoke、correctness全10ケースで生成物・diagnostic・rollbackの
  挙動を維持する。
- runtime metricsで`binary_read_responses == read_requests`（現行worker）を確認する。
- binary化後もread RPCごとのIPC frame数を増やさず、`read_bytes`を不変とする。
- RustからDartへの応答なので、`ipc_bytes_sent`とbenchmarkのwall/user/sysを
  before/afterで記録する。

## Measurement snapshot

100入力・`jobs=1`で、binary envelope実装のbenchmarkは次の値になった。生成物は
byte-identical、no-opは成功し、`binary_read_responses=313`は`read_requests=313`と
一致した。

| metric | binary read run |
| --- | ---: |
| IPC frames sent / received | 729 / 729 |
| IPC bytes sent / received | 286,033 / 505,894 |
| asset requests | 726 |
| `read` requests | 313 |
| `read_bytes` | 183,764 |
| `binary_read_responses` | 313 |
| Rust clean wall | 8.509 s |
| Rust all-file wall | 5.736 s |

直近のJSON bytes-array実装run（別の生成fixture状態）ではIPC bytes sentが722,408
だったため、単純比較ではbinary runが約60%小さい。ただしread payloadの違いと
wall timeの揺らぎを含むため、改善率の確定には同一fixture・複数回測定が必要である。

## Alternatives considered

- 動的asset requestを先読みしてbatch化する: builderが必要とするassetがその時点で
  確定しないため、不要なreadと互換性リスクを増やす。cacheで確実に削れるpositive
  `canRead`とは異なり、今回は採用しない。
- metadata frameとraw bytes frameを分ける: 実装は単純だが、readごとのframe数を
  増やしてIPC待ちを悪化させるため採用しない。
- base64文字列をJSONへ入れる: JSON配列より転送表現は簡潔になるが、base64の
  encode/decodeコストと約33%の膨張が残るため、raw bytesを選んだ。
- build result全体をbinary化する: 効果は大きくなり得るが、commit/diagnosticの
  契約まで同時に変更するため、まずasset readの局所的な実験に限定する。
