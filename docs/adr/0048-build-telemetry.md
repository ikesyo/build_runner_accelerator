# 0048: Bounded, opt-in build tracing with OpenTelemetry

## Investigation (2026-11-06)

Original investigation baseline: main `5ae9ee8`; #164 was an open Draft at
`76dbf94`, based on that main. Its Broad variability motivates this work.
After #164 merged, this branch was rebased onto main `1d6c7ca`, retaining its
snapshot comparison and internal hash/graph/cache changes without duplicating
them. #164 does not add tracing.

| Existing diagnostic | Coverage and cost | Destination / scope |
| --- | --- | --- |
| `WALL_TRACE=1` | RAII Rust intervals: workspace/manifest, scan, dirty check, planning, phases, worker lifecycle/dispatch, asset RPC, decode, cache reconciliation, publication and undo recovery. Disabled check is cached; enabled timestamps, strings and mutex per interval, up to 100,000 records. | Buffered until build end, JSON on stderr; `scripts/summarize_frontend_wall.py` computes unions and gaps. No explicit parent IDs or Dart intervals. |
| `METRICS=1` | Rust pool/client counters, filesystem/graph timings, workspace read-cache counters, scheduler/watch diagnostics. Some counters/timers are always maintained; enabling also computes hypothetical JSON result sizes. | stderr. Pool/client totals include the resident worker lifetime, not just the latest watch build. Filesystem summaries concern the current build. |
| Dart `METRICS=1` | Action, builder/factory, resolver initialization/get/read, cache/IPC and analyzer activity diagnostics; some existing action timers run without metrics. | stderr. Action counters reset at action start; resolver initialization and activity totals have different lifetimes. |
| `ANALYSIS_TRACE=1` with metrics | Detailed dependency loads, file/asset paths, CPU/cache details. Potentially much larger output and additional collection. | stderr; intentionally separate from normal timing and from OTel. |
| `PLAN_ONLY=1` | Planning diagnostics without executing actions; implies plan metrics. | stderr. |

Environment variables above have the prefix `BUILD_RUNNER_ACCELERATOR_`.
The existing wall analyzer remains useful for Rust wall-time attribution.
Converting its logs alone cannot recover correct causal parents across threads,
or Dart execution/resolver intervals. Inferring parents by interval containment
would misclassify overlapping workers and controller waits.

## Decision

Reuse `wall::Session` and `wall::Span` call sites as the instrumentation boundary.
Add the OpenTelemetry Rust API/SDK and official OTLP protobuf JSON serialization
(without HTTP/gRPC transport features, TLS, an async runtime, or a Dart SDK).
The proto crate does bring generated tonic/prost message dependencies; these
avoid maintaining a custom OTLP wire schema. SDK providers are local to each
build, so tracing does not replace an application's global provider. The local
provider uses AlwaysOn plus the admission budgets below; ambient
`OTEL_TRACES_SAMPLER` cannot silently remove the build root.

Each native build / watch iteration gets a fresh `native_build` root. Nested
sessions reuse it. Rust intervals attach SDK contexts; all existing worker
thread entry points capture then attach context inside the thread. Workspace
leases also carry the dispatch context. RAII ends intervals on early returns
and unwinding. The command/watch wrapper sets the root status from its result;
an unwound build retains an interrupted/error status.

Each traced build request carries a sampled W3C `traceparent` referring to its
Rust worker batch (including optional-demand calls). The Dart worker sends an
`otel_action` diagnostic frame in `finally`, before the ordinary result/error.
A Rust SDK bridge reconstructs `dart.action`, `dart.run_builder` and sampled
`dart.resolver_get` children using an epoch anchor and monotonic durations.
This is an internal timing bridge, not an installed Dart OTel provider or
propagation into arbitrary builder packages. It adds no source/output fields
to the build result, graph, dependency records or publication transaction.

`dart.run_builder` includes factory/setup, builder execution and BuildStep
completion, matching the existing timer. Resolver get is nested within it;
resolver calls made later on the returned resolver remain inside the builder
span. `resolver_get_us`/`resolver_get_calls` retain the aggregate across calls.
No synthetic resolver interval is inferred by subtracting accumulated timings.

Rust `worker_batch` includes encode/send, Dart execution, IPC and result handling;
it is not Rust CPU time. `controller_wait` represents blocked orchestration.
Parallel worker spans overlap; use the root duration and unions/critical paths,
never sum all span durations as build elapsed time. Dart shares the host clock
with Rust; clock adjustments can affect cross-process alignment.

Attributes use fixed names: phase, configured builder ID (at most 128 characters), scan asset/byte counts,
per-batch IPC bytes/asset requests/read bytes/RPC microseconds, and current-scope
workspace read-cache hit/miss deltas. Batch counters subtract the client's
entry snapshot; nested demand contributes to its enclosing batch as well.
These are span attributes, not cumulative metric series. Queue wait measures
enqueue-to-worker-receive for parallel input/workspace leases, not total time an
action spends pending in the scheduler. Existing stderr metrics remain available
for deeper analyzer/cache detail; OTel does not enable their more expensive
JSON sizing, activity snapshots or detailed path diagnostics.

## Bounds and failure policy

- Explicit opt-in: `BUILD_RUNNER_ACCELERATOR_OTEL_FILE=/absolute/new/path.ndjson`.
  The destination must not already exist; parent directories must exist. One
  file per native process, shared by watch iterations. Use a path outside the
  watched workspace. Existing files, FIFOs and devices are never opened/replaced.
- Without that variable, no SDK provider, contexts, queue, exporter thread,
  worker diagnostic frames or trace strings are created. Existing wall/metrics
  flags keep their independent behavior.
- At most 10,000 non-root SDK spans per build, plus the root. Admit at start,
  not just at end, to bound the buffer. Root `diagnostic.dropped_spans` reports
  rejected span attempts. This is a prefix budget, not statistical sampling.
- At most 2,048 action timing reports are requested per build, with at most
  16 resolver get intervals each. Remaining actions still build normally;
  root `diagnostic.dropped_action_reports` reports budget rejections; missing
  action spans do not imply no work. Aggregate resolver counts can
  exceed the number of resolver child spans.
- High-volume `receive_frame`, `asset_rpc`, `asset_rpc_lazy` and hypothetical
  JSON-sizing intervals remain wall-only. No per-file/hash OTel spans.
- One bounded export queue (one pending build), one export worker, at most
  32 MiB written per process. Builds buffer SDK records; conversion/writes run
  off the build thread. At most one active, one queued and one exporting bounded
  build buffer can coexist. No retry queue or network client exists.
- Build-end acknowledgment waits at most 100 ms; full/disconnected queues drop
  the trace. File creation/write/byte-limit failures disable file output and
  emit a short stderr diagnostic. They do not change build results. A stalled
  filesystem may leave an exporter thread pending until process termination.
- No options, source content, asset/input names, absolute paths,
  PID or exception text are exported. Builder IDs have configuration-bounded
  cardinality and are recorded on phase spans. The service/scope names are
  fixed. The explicitly selected destination appears only in local configuration.
- Abrupt process termination (including SIGKILL or native default signal
  termination) cannot execute RAII/export. A killed worker yields a failed root
  and closed Rust intervals when the frontend handles EOF, but cannot return
  its final Dart timing report. A timeout/drop/file limit can leave incomplete
  traces. Do not treat missing spans as zero duration.

## Local use and OTLP

```bash
trace_dir=$(mktemp -d)
BUILD_RUNNER_ACCELERATOR_OTEL_FILE="$trace_dir/build.ndjson" \
  dart run build_runner_accelerator build
# Existing wall analysis can be requested independently:
BUILD_RUNNER_ACCELERATOR_WALL_TRACE=1 \
  dart run build_runner_accelerator build 2>"$trace_dir/wall.log"
python3 scripts/summarize_frontend_wall.py "$trace_dir/wall.log"
python3 scripts/check_otel_trace.py "$trace_dir/build.ndjson"
```

Each line is a standard OTLP JSON `ExportTraceServiceRequest`, one build,
including `service.name=build_runner_accelerator`. Inspect locally with:

```bash
jq -r '.resourceSpans[].scopeSpans[].spans[] |
  [.name, .traceId, .spanId, .parentSpanId,
   .startTimeUnixNano, .endTimeUnixNano] | @tsv' "$trace_dir/build.ndjson"
```

For an existing Collector/Jaeger OTLP HTTP JSON receiver, explicitly send each
line to its configured trace endpoint, for example a local receiver:

```bash
while IFS= read -r batch; do
  printf '%s\n' "$batch" | curl --fail --silent --show-error \
    --connect-timeout 1 --max-time 2 \
    -H 'Content-Type: application/json' --data-binary @- \
    http://127.0.0.1:4318/v1/traces
done < "$trace_dir/build.ndjson"
```

The build never contacts that endpoint or honors `OTEL_EXPORTER_OTLP_ENDPOINT`.
An unavailable backend only fails this explicit post-build command. Local JSON
is sufficient without a backend. Direct live OTLP export, arbitrary external
parent contexts, end-to-end launcher/AOT compiler spans, deep analyzer spans,
per-action queue residence and cancellation of a hard-killed frontend are not
implemented. Stable Rust, pure Rust dependencies and the existing Dart range
are retained; other platform native execution belongs to the existing five
release lanes.

## Validation (2026-11-06)

Linux x86_64, stable Rust 1.98.1, Dart 3.13.3, Release frontend, resolved
`fixtures/json_serializable_app`, two workers, warm AOT. An additional temporary
copy of the model (distinct class/part name) exercises two parallel inputs and
four actions; it and its generated output are removed afterward. AOT had to be
prepared once because the worker source changed. Reuse the repository SDK with
`DART_SDK=$PWD/.toolchains/dart/dart-sdk`, `PUB_CACHE=$PWD/.pub-cache` and
`BUILD_RUNNER_ACCELERATOR_CACHE=$PWD/.toolchains/accelerator-cache` in this
managed checkout; the SDK wrapper alone is insufficient for AOT SDK discovery.

Command under comparison (native command, including its process supervisor;
not the public Dart launcher):

```bash
rust/target/release/build_runner_accelerator build \
  --root "$PWD/fixtures/json_serializable_app" \
  --dart "$PWD/.toolchains/dart-wrapper" --force-aot --jobs 2
```

No compilation or other checks ran alongside timing. Two order-reversed pairs
per case: off/on, on/off. Broad edits only change comments in both inputs,
forcing regeneration while preserving generated bytes. Single samples in
execution order, milliseconds:

| Case | Off, On | On, Off |
| --- | --- | --- |
| No-op | 12.186, 12.043 | 12.281, 12.076 |
| Two-input incremental | 115.912, 161.256 | 118.626, 158.757 |

The incremental difference reverses sign; two pairs on this tiny fixture do
not establish a stable overhead percentage or a production performance claim.
Off mode was inspected for absent SDK/context/exporter/worker-report allocation
paths; this is not a comparison against a separately compiled main binary.
Timing samples preceded the final builder-ID and drop-summary metadata additions.
Those captures contain 14 spans / 6,118 bytes for No-op and 96 spans /
41,836–41,839 bytes for incremental. A final untimed two-worker capture contains
96 spans / 43,282 bytes, with valid parents even under ambient
`OTEL_TRACES_SAMPLER=always_off`. A sentinel in `OTEL_RESOURCE_ATTRIBUTES` is
not exported; existing-file and FIFO destinations fail export without overwriting
or blocking the build. All generated file inventories/bytes match in off/on/sink
failure cases. An unavailable file parent returns success in 12.048 ms. Setting
an unreachable `OTEL_EXPORTER_OTLP_ENDPOINT` in every sample causes no network
export. Explicit post-build curl to an unavailable local receiver fails
independently (exit 7); no Collector deployment or live-backend acceptance test
was performed.

Failure injection verifies root and Dart error status, completed parent chains,
and unchanged committed output/graph bytes, followed by successful recovery.
Watch checks cover initial build, successful edit, builder error and recovery
with distinct root trace IDs. Killing the resident worker yields closed Rust
spans and failed roots on subsequent edits. Existing watch behavior retains
that dead pool (repeated broken pipe); stopping/relaunching the frontend
recovers with a fresh trace. Automatic dead-worker replacement is not added by
this diagnostic change. Idle watch termination has no unfinished build root;
hard termination during a build remains the limitation above.

Checks:

- `cargo test --locked --manifest-path rust/Cargo.toml`: 234 passed, 3 ignored,
  including five telemetry tests for parallel context/early error, budgets,
  timestamp/status/parent reconstruction and privacy, broken sinks and stalled /
  full / disconnected export queues.
- Cargo Release build, formatting and all-target/all-feature Clippy; Dart
  fatal-info analysis and the 14 protocol tests (single/batch optional context).
- Existing wall analyzer's 15 Python tests.
- `python3 scripts/check_otel_trace.py TRACE.ndjson` validates actual standalone,
  parallel, failure/recovery and watch captures: one root per build, unique IDs,
  same trace ID, complete acyclic parents and interval containment.

Other-platform execution, full Dart tests, the long verify/watch/builder matrix
and stock comparison reruns are left to existing CI. The focused checks reuse
resolved dependencies and the new warm AOT instead of repeating Clean/AOT
preparation. Raw traces, logs and temporary measurement scripts are not committed.


### Rebase and native CI correction

The initial PR run passed Linux native build, both Dart SDK jobs and the
integration jobs, but macOS ARM64 and Windows x64 failed with unresolved
OpenTelemetry crates. The dependencies had mistakenly been appended below the
Linux-only dependency header. They now belong to common dependencies; only
libc remains Linux-specific. No CI steps are skipped or weakened.

The lockfile conflict with merged #164 is resolved starting from main's lockfile,
retaining every existing main package/version and adding the telemetry closure.
The preceding timing results remain historical evidence from before this rebase;
this dependency-scope fix does not repeat benchmarks.

Rebased verification: locked Rust tests pass (240 passed, 3 ignored), formatting,
all-target/all-feature Clippy, release metadata and all 32 Python tests pass.
Release type checks pass for all five distribution targets: Linux x64/ARM64,
macOS ARM64, Windows x64/ARM64. Non-host checks use `--features blake3/pure`
because cross C compilers are unavailable; the Linux x64 host uses default
BLAKE3 features. These are type checks, not non-host native execution/linking.
The existing native CI lanes continue to exercise default-feature native builds.
