# 0048: Bounded, opt-in build tracing with OpenTelemetry

## Context

Build performance investigations need to distinguish Rust orchestration, Dart
builder/resolver work, IPC, caches and publication. Existing diagnostics expose
intervals and counters independently, without shared causal parents across
language and thread boundaries.

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
The official schema avoids maintaining a custom OTLP wire format.
SDK providers are local to each build, so tracing does not replace an application's global provider. The local
provider uses AlwaysOn plus the admission budgets below; ambient
`OTEL_TRACES_SAMPLER` cannot silently remove the build root.

Each native build / watch iteration gets a fresh `native_build` root. Nested
sessions reuse it. Rust intervals attach SDK contexts; all existing worker
thread entry points capture then attach context inside the thread. Workspace
leases also carry the dispatch context. RAII ends intervals on early returns
and unwinding. The command/watch wrapper sets the root status from its result;
an unwound build retains an interrupted/error status.

Each traced build request carries a sampled W3C `traceparent` referring to its
Rust worker batch (including optional-demand calls), with a bounded single-use
action ticket. Responses must match an issued ticket and its parent before
consuming span budget. The Dart worker sends an
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
  root `diagnostic.dropped_action_reports` counts budget rejections and rejected
  duplicate/invalid reports. Missing action spans do not imply no work. Aggregate resolver counts can
  exceed the number of resolver child spans.
- High-volume `receive_frame`, `asset_rpc`, `asset_rpc_lazy` and hypothetical
  JSON-sizing intervals remain wall-only. No per-file/hash OTel spans.
- One bounded export queue (one pending build), one export worker, at most
  32 MiB written per process. Builds buffer SDK records; conversion/writes run
  off the build thread. At most one active, one queued and one exporting bounded
  build buffer can coexist. One warning worker and a one-message warning queue
  keep stalled stderr off build/export threads; excess warnings are dropped.
  No retry queue or network client exists.
- Build-end acknowledgment waits at most 100 ms; full/disconnected queues drop
  the trace. File creation/write/byte-limit failures disable file output and
  enqueue a best-effort stderr diagnostic through a separate warning worker.
  They do not change build results. A stalled filesystem may leave an exporter thread pending until process termination.
- No options, source content, asset/input names, absolute paths,
  PID or exception text are exported. Builder IDs have configuration-bounded
  cardinality and are recorded on phase spans. The service/scope names are
  fixed. The explicitly selected destination appears only in local configuration.
- Abrupt process termination (including SIGKILL or native default signal
  termination) cannot execute RAII/export. A killed worker yields a failed root
  and closed Rust intervals when the frontend handles EOF, but cannot return
  its final Dart timing report. A timeout/drop/file limit can leave incomplete
  traces. Do not treat missing spans as zero duration.

## Consequences

Builds export local OTLP JSON only. Sending traces to a backend is a separate,
explicit operation, so backend availability cannot affect build success.
Direct live OTLP export, arbitrary external parent contexts, launcher/AOT
compiler spans, deep analyzer spans and per-action queue residence are outside
this instrumentation boundary.

The admission budgets keep tracing bounded but allow incomplete traces. They
are prefix limits rather than statistical sampling, so they cannot support
unbiased comparisons of individual action distributions. Opt-in remains the
default because representative production overhead has not been established.

See [development](../development.md#build-telemetry) for activation and local
inspection, and [the telemetry overhead report](../benchmarks/build-telemetry-2026-11.md)
for measurement conditions and evidence limits.
