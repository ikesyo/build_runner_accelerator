# Shared Rust output buffers (2026-10-07)

Compared main `308fdc6` with the shared-output-buffer implementation. Both
release binaries used Rust 1.98.1, Dart 3.13.3, the same prepared AOT worker
(SHA-256 `6f246bc4f0d4878b52ea551d594741bcab92986ca0729aee4f596a0f8b8d6e4d`),
workspace paths, pub cache and retained shared/OS caches. Linux x86_64,
AMD EPYC 7763; jobs=2. Metrics and traces were disabled. Timed comparisons ran
after the correctness scripts finished.

## Ownership and copy accounting

Previously each output was copied from the received frame into a `Vec<u8>`,
then copied again into the overlay and pending commit outputs. The optional
path also copied into its early demand overlay before normal registration.
After registration, overlay and pending commit each retained a full allocation.

Now decoding copies each checked output range directly into an `Arc<[u8]>`.
This preserves one receive copy without an intermediate Vec-to-Arc conversion
(which would allocate and copy again). The result, overlay and pending commit
share immutable bytes. Normal registration removes two payload copies per
output; optional registration removes three, including its early overlay
insertion. A single overlay asset read now clones an Arc; batch read payload
concatenation remains unchanged. The part-directive filter borrows overlay or
existing disk-cache bytes rather than cloning their contents.

The received frame is freed after decoding. Result references end when results
are recorded; optional references last until their deferred results are drained.
Overlay references last through phase execution/deletion handling, and are
released when successful execution enters commit. Pending output references
last until their atomic file writes finish. Aborted transactions release their
references without publishing output or graph state. No shared output is
retained in a new persistent cache.

For the measured clean build, output bytes total 96 MiB + 1,200 bytes: the
removed registration copies total **192 MiB + 2,400 bytes**, while the steady
retained overlay/commit payload drops from approximately 192 to 96 MiB. The
broad case rebuilds 47 inputs (one was already changed in the one-file case),
removing approximately 188 MiB of copies. These are code-level copy counts,
not measured memory savings or speedups. Large optional outputs were not timed.

## Bounded verification

- `cargo fmt --manifest-path rust/Cargo.toml --check`
- `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings`
- `cargo test --manifest-path rust/Cargo.toml`: 110 passed, including frame
  validation/limits, binary result ranges, overlay blobs and commit/deletion
  tests. The added test checks allocation identity, empty/binary payloads,
  optional pre-registration ownership, overlay removal and abort release.
- `BUILD_RUNNER_ACCELERATOR_BIN=$PWD/rust/target/release/build_runner_accelerator bash scripts/correctness_arbitrary_builder.sh`:
  all cases passed, including stock equality, generated/input deletion, rename,
  failure recovery without commit, affected actions, filtering and conflicts.
- Same binary with `bash scripts/correctness_optional_builder.sh`: all cases
  passed, including demand/no-demand, no-op, incremental, failed demand without
  commit, recovery, deletion and rename.

Broader compatibility/watch verification is left to CI.

## Measurement

[benchmark.py](benchmark.py) expands the tracked arbitrary echo-builder fixture
to 48 inputs of 2 MiB each, producing 48 large outputs and 48 small metadata
outputs. Untimed stock builds establish SHA-256 references for clean, no-op,
one-file and broad actual edits. All **24 timed native runs** matched all
96 stock outputs. Three repeats alternate lane order, clearing native graphs
and generated outputs for clean while retaining prepared worker and caches.
The native command excludes the Dart launcher and AOT compilation. Preparation,
source edits and equality hashing are outside timing.

Medians (main → candidate); memory in MiB:

| Case | Wall seconds | CPU seconds | Largest single-process peak RSS | Sampled tree peak RSS sum | Sampled tree peak PSS sum |
| --- | ---: | ---: | ---: | ---: | ---: |
| Clean | 2.427 → 2.361 | 3.490 → 3.467 | 623.8 → 624.2 | 1455.5 → 1349.6 | 1447.6 → 1341.8 |
| No-op | 0.661 → 0.645 | 0.690 → 0.679 | 25.4 → 25.4 | 11.0 → 11.0 | 10.6 → 10.5 |
| One-file | 1.161 → 1.146 | 1.157 → 1.167 | 48.6 → 48.5 | 45.5 → 34.6 | 44.4 → 33.4 |
| Broad (47 inputs) | 2.822 → 2.777 | 3.879 → 3.921 | 623.8 → 623.6 | 1403.6 → 1313.5 | 1395.9 → 1305.8 |

Clean wall ranges: main 2.368–2.451 s, candidate 2.339–2.427 s. Broad wall
ranges: main 2.742–2.884 s, candidate 2.688–2.836 s. Timing distributions
intersect and CPU does not consistently improve; this small sampled comparison
does not establish a general speedup. The sampled aggregate memory is lower
in the large-output cases; the largest individual process peak is essentially
unchanged.

CPU comes from `wait4` user+system usage of the frontend and waited descendants.
`ru_maxrss` reports the largest individual high-water mark propagated through
that child tree, **not simultaneous aggregate memory**. Aggregate RSS/PSS are
sampled separately from `/proc/*/status` PPid relationships and
`smaps_rollup`, sleeping 50 ms between scans. RSS sums count shared pages more
than once; PSS apportions them. Scans are not atomic and can miss short-lived
processes or peaks. Sampler CPU is excluded from CPU usage, but its contention
and sampling/detection delay affect wall time. No-op timings and tiny memory
changes should not be interpreted as benefits of output sharing.

An initial sampler using task `children` files could not discover workers in
this environment; those readings were discarded. The reported comparison uses
PPid discovery throughout. Initial harness setup fixes and resumed untimed
preparation do not contribute any reported timing rows. Raw logs, metadata and
JSONL remain in the disposable local measurement workspace.

Reproduce with a separately built main release binary and a fresh work directory:

```sh
python3 docs/benchmarks/output-sharing-2026-10/benchmark.py \
  --repo "$PWD" \
  --baseline /absolute/path/to/main/release/build_runner_accelerator \
  --candidate "$PWD/rust/target/release/build_runner_accelerator" \
  --work /absolute/path/to/new-disposable-directory --repeats 3
```

## Received-frame sharing candidate

Checked the owned single/batch decode paths and checked cursor ranges. A future
private buffer/range wrapper could move the received `Vec<u8>` into
`Arc<Vec<u8>>` without copying, sharing validated ranges via immutable slice
access. Converting that whole Vec to `Arc<[u8]>` would itself copy the frame.
Shared ranges could remove the remaining per-output receive copies, but even
one retained output would keep the entire batch frame (including metadata and
other outputs) alive; committing/deleting individual outputs could not release
those portions. It also needs a new slice wrapper and serde/accessor changes.
This PR keeps per-output allocations and changes no framing, validation, limits
or output bytes. Frame sharing was assessed by ownership/code inspection; no
prototype performance claim is made.
