# IPC and FFI investigation

This experiment measures the existing Rust frontend ↔ resident Dart worker
boundary before attempting an FFI replacement. It is intentionally separate
from the release benchmark summary until a reproducible run demonstrates that
IPC is a material part of the measured wall time.

## What is measured

With `BUILD_RUNNER_ACCELERATOR_METRICS=1`, the native frontend emits the
existing `Rust metrics:` line with two additional timings:

- `ipc_write_us`: JSON/binary serialization, pipe write, and flush for frames
  sent from Rust to Dart;
- `ipc_read_us`: frame read and decode on the Rust side. This includes blocking
  while Dart produces a response, so it is a worker wait measurement and not a
  pipe-only measurement.

Each Dart build profile now includes asset RPC timings:

- `asset_rpc_us`: total time from sending an asset request to receiving its
  response;
- `asset_rpc_send_us`: request encoding and `IOSink` flush time;
- `asset_rpc_wait_us`: time waiting for the response, including any nested
  optional-builder work;
- `asset_rpc_read_us` (and its `send`/`wait` variants): the same timings for
  `asset_request(read)` only;
- operation counts for `read`, `can_read`, and `find_assets`.

The existing Rust `asset_rpc_us`, operation-specific `*_rpc_us`, `read_bytes`,
frame counts, and frame byte counts remain available. The Dart and Rust values
intentionally overlap: the overlap is useful for estimating transport and
framing overhead, while the Dart total captures the user-visible RPC wait.

The summary helper reports `asset_rpc_overhead_estimate_us` as
`dart_asset_rpc_us - rust_asset_rpc_us`, and the read-only counterpart as
`asset_read_rpc_overhead_estimate_us`. Treat both as approximations: nested
optional-builder work and Dart scheduling can be included on the Dart side.

## Initial measurement (2026-09-19)

The first run used the pinned Rust 1.98.1 and Dart 3.13.3 SDKs, the release
frontend, one worker, the direct worker path, and the current JSON fixture. The
one-file case was repeated three times; `read` issued 33 calls per build.

| case | wall time | Dart `read` RPC | Rust `read` handling | estimated IPC overhead |
| --- | ---: | ---: | ---: | ---: |
| one-file (n=3, median) | 4,286 ms | 47.5 ms | 2.4 ms | 44.7 ms |
| broad (n=1) | 4,244 ms | 37.5 ms | 3.4 ms | 34.2 ms |

The read-only estimate is roughly 0.8–1.0% of this fixture's wall time. It is
large enough to justify a narrowly scoped shared-memory/FFI experiment, but it
does not support a full IPC migration yet. The current result is a baseline for
that PoC, not a claim that the entire estimate is removable: a shared-memory
implementation still pays synchronization and copying costs.

## Read-only shared-memory PoC (2026-09-19)

The first implementation keeps the Rust/Dart process boundary and the request
and response control frames. On Linux and macOS, each Rust worker creates a
private, 0600 file-backed `mmap` slot and passes its path to the Dart worker.
For a successful `asset_request(read)`, Rust copies the bytes into that slot
and sends only a JSON response header. Dart maps the file read-only, copies the
announced slice into the existing read cache, and then the next read may reuse
the slot. Reads larger than the configured slot fall back to the existing
binary response. A worker that does not advertise the capability also falls
back automatically.

This is deliberately a FFI-equivalent transport experiment, not a production
ABI: it is currently limited to Linux and macOS, uses one synchronous slot per
worker, and keeps the pipe for all control traffic and build results. No
production package dependency is added; the Dart side calls the platform
system library (`libc.so.6` on Linux or `libSystem.B.dylib` on macOS) through
`dart:ffi`.

Enable it for the same benchmark matrix with:

```sh
BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY=1 \
BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY_CAPACITY=$((16 * 1024 * 1024)) \
DART_BIN=/absolute/path/to/dart \
BUILD_RUNNER_ACCELERATOR_BIN=/absolute/path/to/build_runner_accelerator \
CASES='no-op one-file broad' REPEATS=3 ACCELERATOR_JOBS=1 \
scripts/benchmark_ipc.sh
```

The paired one-file Linux run used the pinned Dart 3.13.3/Rust 1.98.1 toolchains,
the release frontend, one direct worker, and three repeats. All six measured
builds produced the same output hash (`51d4d65d…`). The median read-only
transport figures were:

The absolute wall time is lower than the earlier initial-measurement row; the
two runs were collected at different points in the local workspace. The
transport comparison below is paired within this run and is the relevant PoC
signal.

| metric | binary-read baseline | shared-memory read | change |
| --- | ---: | ---: | ---: |
| wall time | 1,886 ms | 1,880 ms | −0.3% |
| Dart `read` RPC | 14.26 ms | 12.15 ms | −14.8% |
| Rust `read` handling | 0.74 ms | 2.38 ms | +1.64 ms |
| estimated read transport overhead | 13.61 ms | 9.66 ms | −29.0% |
| Rust bytes sent | 90,336 | 33,709 | −56,627 bytes |
| shared-memory read responses | 0 | 33 | — |

The Linux sample shows a meaningful reduction in read transport bytes and estimated
read overhead, but only a sub-percent wall-time change on this fixture. The
extra Rust time includes the copy into the mapping and the JSON header write;
the Dart side still makes a defensive copy into its cache. Treat this as
evidence that a read-only PoC is viable, not as justification for migrating
other asset operations or the full worker protocol.

## Reproduction

Use one SDK, pub cache, and native binary for all cases. The helper reuses
`benchmark_current_baseline.sh`, including its warm-up behavior and output hash
check:

```sh
DART_BIN=/absolute/path/to/dart \
BUILD_RUNNER_ACCELERATOR_BIN=/absolute/path/to/build_runner_accelerator \
CASES='no-op one-file broad' \
REPEATS=3 \
ACCELERATOR_JOBS=1 \
scripts/benchmark_ipc.sh
```

The helper prints one JSON record per measured stderr log and leaves the raw
results under the reported temporary directory. `ACCELERATOR_LAUNCHER=1` can
be added for a project-facing launcher measurement; keep direct-front-end and
launcher-inclusive runs separate.

The baseline defaults to offline dependency resolution for repeatability. On a
fresh pub cache, run once with `PUB_GET_OFFLINE=0` (and keep the resulting cache
for subsequent offline runs).

For comparisons, repeat the same matrix with worker AOT already prewarmed and
record:

- Dart SDK and Rust versions;
- worker mode (AOT, kernel, or script);
- worker count;
- clean/no-op/one-file/broad case;
- wall time and output hash;
- `rust_ipc_*`, `rust_asset_rpc_us`, operation-specific `rust_*_rpc_us`,
  `dart_asset_rpc_*`, request counts, and both overhead estimates.

## Decision rule

Do not infer FFI value from frame counts alone. If the measured Dart asset-RPC
time and the Rust worker-wait time are only a small fraction of one-file and
no-op wall time, keep the executable + IPC boundary. If they consistently reach
the tens-of-milliseconds range on representative generators, prototype only a
single `read` path with the same correctness fixture and compare it against the
recorded IPC run.

The first FFI prototype should preserve the current process boundary for the
worker and should not embed the Dart VM. It should be an experimental backend,
not a replacement for the signed executable path or the automatic Dart
fallback.
