# ADR-0025: 子workerとのtransportはstdin/stdout pipeを維持する

- Status: Accepted
- Date: 2026-09-04

## Context

Rust frontendはDart workerを自分の子processとして起動し、workerのlifecycleを
所有している。現在のstdin/stdoutは、4-byte length prefixを持つbinary-safeなframe
channelであり、stdoutはログ出力には使わず、診断はstderrへ分離している。build resultの
binary化はpayload encodingの判断であり、transportの変更とは独立している。

## Decision

- v1では、Rust parentとDart childのtransportにstdin/stdout pipeを使い続ける。
- stdoutはlength-prefixed IPC frame専用、stderrは人間向けdiagnostic専用とする。pipeを
  text streamとして扱わず、JSON metadataとbinary payloadの双方を同じframe protocolで運ぶ。
- Unix domain socketへの変更は行わない。workerがfrontendから独立したdaemonになり、複数
  client、reconnect、外部processからの接続、またはFD passingが必要になった場合に、別ADRで
  Unix socket（parent-childだけならpathless socketpairを含む）を再評価する。
- TCP loopback、shared memory、temp fileはv1のtransport候補にしない。

## Measurement snapshot

100入力・`jobs=1`の実測では、asset readとbuild resultのbinary化によって同じworker
session内のpayloadを削減できた。build resultだけでもbinary frameは194,278 bytes、
旧JSON換算は417,128 bytesだった。これはtransportを変更せずに得られる削減である。
transport自体の切り替えはこのpayload差を変えないため、現段階ではpipeとUDSのsynthetic
throughput差を追うより、実builderのframe bytesとwall timeを優先して測る。

## Consequences

- process spawn、socket path、permission、cleanup、platform-specific実装を増やさずに
  worker lifecycleとbackpressureを扱える。
- stdin/stdout pipeはWindowsを含むchild process境界に適用しやすい。一方、Unix socket固有の
  reconnectやFD passingは利用できない。
- UDSへ替えてもframe framingとpayload serializationは必要であり、JSON bytes配列の問題は
  解決しない。そのため先にADR-0024のraw bytes化を行う。
- 将来daemon化する場合は、transport abstraction、認証/permission、socket lifecycle、
  reconnect、multi-clientの検証をまとめて行う必要がある。

## Alternatives considered

- Unix domain socket: daemonや複数clientには適するが、現在の単一parent-child lifecycleには
  setupとplatform制約が増えるため採用しない。
- Unix `socketpair`: pathlessで効率的だがUnix限定で、childのstdin/stdoutへのFD wiringを
  追加で実装する必要があるため、現行pipeを置き換える根拠がない。
- TCP loopback: 接続管理、port、permissionの問題を加え、local child IPCに不要なnetwork
  semanticsを持ち込むため採用しない。
- shared memory / memfd: 巨大payloadのcopy削減には有効だが、FD passingやcleanupを要求し、
  通常のbuild resultには過剰なため採用しない。
