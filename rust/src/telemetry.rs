//! Opt-in OTel bridge for existing wall intervals and worker timing reports.
//! A bounded build buffer and one bounded export queue keep disk IO off builders.
use opentelemetry::trace::{
    Span as _, SpanContext, SpanId, Status, TraceContextExt, TraceFlags, TraceId, TraceState,
    Tracer, TracerProvider,
};
use opentelemetry::{Context, ContextGuard, KeyValue};
use opentelemetry_proto::{
    tonic::collector::trace::v1::ExportTraceServiceRequest,
    transform::trace::tonic::group_spans_by_resource_and_scope,
};
use opentelemetry_sdk::{
    error::OTelSdkResult,
    trace::{SdkTracerProvider, Span, SpanData, SpanProcessor},
};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    fs::OpenOptions,
    io::Write,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const MAX_SPANS: usize = 10_000;
const MAX_REPORTS: usize = 2048;
const MAX_BYTES: usize = 32 * 1024 * 1024;
static ACTIVE: Mutex<Option<Arc<Build>>> = Mutex::new(None);

pub(crate) fn enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os("BUILD_RUNNER_ACCELERATOR_OTEL_FILE").is_some())
}

#[derive(Clone, Debug, Default)]
struct Buffer(Arc<Mutex<Vec<SpanData>>>);
impl SpanProcessor for Buffer {
    fn on_start(&self, _: &mut Span, _: &Context) {}
    fn on_end(&self, span: SpanData) {
        self.0.lock().unwrap().push(span);
    }
    fn force_flush(&self) -> OTelSdkResult {
        Ok(())
    }
    fn shutdown_with_timeout(&self, _: Duration) -> OTelSdkResult {
        Ok(())
    }
}
struct Build {
    provider: SdkTracerProvider,
    buffer: Buffer,
    admitted: AtomicUsize,
    reports: AtomicUsize,
    rejected_reports: AtomicUsize,
    pending_reports: Mutex<BTreeMap<u64, SpanContext>>,
    root: Context,
}

pub(crate) struct Session(Option<(Arc<Build>, ContextGuard)>);
impl Session {
    pub(crate) fn new() -> Self {
        if !enabled() {
            return Self(None);
        }
        let mut active = ACTIVE.lock().unwrap();
        if active.is_some() {
            return Self(None);
        }
        let buffer = Buffer::default();
        let provider = SdkTracerProvider::builder()
            .with_sampler(opentelemetry_sdk::trace::Sampler::AlwaysOn)
            .with_span_processor(buffer.clone())
            .build();
        let root = Context::new().with_span(
            provider
                .tracer("build_runner_accelerator")
                .start_with_context("native_build", &Context::new()),
        );
        root.span().set_status(Status::error("build interrupted"));
        let guard = root.clone().attach();
        let build = Arc::new(Build {
            provider,
            buffer,
            admitted: AtomicUsize::new(0),
            reports: AtomicUsize::new(0),
            rejected_reports: AtomicUsize::new(0),
            pending_reports: Mutex::new(BTreeMap::new()),
            root,
        });
        *active = Some(build.clone());
        Self(Some((build, guard)))
    }
    pub(crate) fn finish(&self, success: bool) {
        if let Some((build, _)) = &self.0 {
            build.root.span().set_status(if success {
                Status::Ok
            } else {
                Status::error("build failed or cancelled")
            });
        }
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        let Some((build, _)) = &self.0 else { return };
        *ACTIVE.lock().unwrap() = None;
        let dropped = build
            .admitted
            .load(Ordering::Relaxed)
            .saturating_sub(MAX_SPANS);
        build
            .root
            .span()
            .set_attribute(KeyValue::new("diagnostic.dropped_spans", dropped as i64));
        build.root.span().set_attribute(KeyValue::new(
            "diagnostic.dropped_action_reports",
            build
                .reports
                .load(Ordering::Relaxed)
                .saturating_sub(MAX_REPORTS)
                .saturating_add(build.rejected_reports.load(Ordering::Relaxed)) as i64,
        ));
        build.root.span().end();
        let spans = std::mem::take(&mut *build.buffer.0.lock().unwrap());
        export(spans);
    }
}

#[derive(Clone, Debug)]
struct IpcParent(SpanContext);

pub(crate) struct Interval {
    context: Context,
    _guard: ContextGuard,
}
impl Interval {
    pub(crate) fn new(stage: &'static str) -> Option<Self> {
        if !enabled()
            || matches!(
                stage,
                "receive_frame" | "asset_rpc" | "asset_rpc_lazy" | "diagnostic_json_size"
            )
        {
            return None;
        }
        let build = ACTIVE.lock().unwrap().clone()?;
        Self::in_build(stage, &build)
    }
    fn in_build(stage: &'static str, build: &Build) -> Option<Self> {
        if build.admitted.fetch_add(1, Ordering::Relaxed) >= MAX_SPANS {
            return None;
        }
        let current = Context::current();
        let parent = if current.span().span_context().is_valid() {
            &current
        } else {
            &build.root
        };
        let span = build
            .provider
            .tracer("build_runner_accelerator")
            .start_with_context(stage, parent);
        let mut context = parent.with_span(span);
        if stage.starts_with("worker_") {
            context = context.with_value(IpcParent(context.span().span_context().clone()));
        }
        let guard = context.clone().attach();
        Some(Self {
            context,
            _guard: guard,
        })
    }
    pub(crate) fn attribute(&self, key: &'static str, value: u64) {
        self.context
            .span()
            .set_attribute(KeyValue::new(key, value.min(i64::MAX as u64) as i64));
    }
    pub(crate) fn phase(&self, phase: u32, builder: &str) {
        self.context.span().set_attributes([
            KeyValue::new("build.phase", phase as i64),
            KeyValue::new(
                "build.builder",
                builder.chars().take(128).collect::<String>(),
            ),
        ]);
    }
}
impl Drop for Interval {
    fn drop(&mut self) {
        self.context.span().end();
    }
}

/// Capture before spawning; attach inside the new thread, never move a guard.
pub(crate) fn capture() -> Option<Context> {
    enabled().then(Context::current)
}
pub(crate) fn attach(context: Option<Context>) -> Option<ContextGuard> {
    context.map(Context::attach)
}

/// Issue a bounded, single-use report ticket for one action, including batch items.
pub(crate) fn request_context() -> Option<(String, u64)> {
    if !enabled() {
        return None;
    }
    let build = ACTIVE.lock().unwrap().clone()?;
    let current = Context::current();
    issue_report(&build, &current.get::<IpcParent>()?.0)
}

fn issue_report(build: &Build, parent: &SpanContext) -> Option<(String, u64)> {
    let index = build.reports.fetch_add(1, Ordering::Relaxed);
    if index >= MAX_REPORTS {
        return None;
    }
    let id = index as u64 + 1;
    build
        .pending_reports
        .lock()
        .unwrap()
        .insert(id, parent.clone());
    Some((
        format!("00-{}-{}-01", parent.trace_id(), parent.span_id()),
        id,
    ))
}

/// Consume only a ticket whose parent matches; duplicates and stale reports cannot
/// spend span admission budget. Matching tickets are consumed even if timing is invalid.
fn report_parent(build: &Build, message: &Value) -> Option<Context> {
    let valid = || {
        let id = message.get("otel_report_id")?.as_u64()?;
        let context = parent(message.get("traceparent")?.as_str()?)?;
        let mut pending = build.pending_reports.lock().unwrap();
        let expected = pending.get(&id)?;
        if context.span().span_context().trace_id() != expected.trace_id()
            || context.span().span_context().span_id() != expected.span_id()
        {
            return None;
        }
        pending.remove(&id);
        Some(context)
    };
    let context = valid();
    if context.is_none() {
        build.rejected_reports.fetch_add(1, Ordering::Relaxed);
    }
    context
}

fn parent(value: &str) -> Option<Context> {
    let parts: Vec<_> = value.split('-').collect();
    if parts.len() != 4
        || parts[0] != "00"
        || parts[1].len() != 32
        || parts[2].len() != 16
        || parts[3] != "01"
    {
        return None;
    }
    let span = SpanContext::new(
        TraceId::from_hex(parts[1]).ok()?,
        SpanId::from_hex(parts[2]).ok()?,
        TraceFlags::SAMPLED,
        true,
        TraceState::default(),
    );
    span.is_valid()
        .then(|| Context::new().with_remote_span_context(span))
}

/// Timing reports use monotonic durations and one epoch anchor per action.
/// Never ingest builder labels, paths, options, source text, or error messages.
pub(crate) fn worker_report(message: &Value) {
    if !enabled() {
        return;
    }
    let Some(build) = ACTIVE.lock().unwrap().clone() else {
        return;
    };
    record_worker_report(&build, message);
}

fn record_worker_report(build: &Build, message: &Value) {
    let Some(context) = report_parent(build, message) else {
        return;
    };
    if !record_action(build, message, context) {
        build.rejected_reports.fetch_add(1, Ordering::Relaxed);
    }
}

fn record_action(build: &Build, message: &Value, context: Context) -> bool {
    let Some(start) = message
        .get("start_us")
        .and_then(Value::as_u64)
        .and_then(|us| UNIX_EPOCH.checked_add(Duration::from_micros(us)))
    else {
        return false;
    };
    let Some(duration) = message
        .get("duration_us")
        .and_then(Value::as_u64)
        .filter(|us| *us <= 86_400_000_000)
    else {
        return false;
    };
    let Some(end) = start.checked_add(Duration::from_micros(duration)) else {
        return false;
    };
    if build.admitted.fetch_add(1, Ordering::Relaxed) >= MAX_SPANS {
        return false;
    }
    let tracer = build.provider.tracer("build_runner_accelerator.dart");
    let mut span = tracer.build_with_context(
        tracer.span_builder("dart.action").with_start_time(start),
        &context,
    );
    for key in [
        "resolver_get_us",
        "resolver_get_calls",
        "run_builder_us",
        "outputs",
        "reads",
        "resolver_reads",
    ] {
        if let Some(value) = message.get(key).and_then(Value::as_i64).filter(|n| *n >= 0) {
            span.set_attribute(KeyValue::new(key, value));
        }
    }
    if message.get("success").and_then(Value::as_bool) == Some(true) {
        span.set_status(Status::Ok);
    } else {
        span.set_status(Status::error("builder failed or cancelled"));
    }
    let action = TimedSpan {
        context: context.with_span(span),
        offset: 0,
        end: duration,
    };
    let run = message
        .get("run_builder_start_us")
        .and_then(Value::as_u64)
        .zip(message.get("run_builder_us").and_then(Value::as_u64));
    let mut run_context = None;
    if let Some((offset, length)) = run {
        run_context = timed_child(build, &action, "dart.run_builder", start, offset, length);
    }
    if let Some(spans) = message.get("resolver_spans").and_then(Value::as_array) {
        for item in spans.iter().take(16) {
            if let Some((offset, length)) = item
                .get("offset_us")
                .and_then(Value::as_u64)
                .zip(item.get("duration_us").and_then(Value::as_u64))
                && let Some(child) = timed_child(
                    build,
                    run_context.as_ref().unwrap_or(&action),
                    "dart.resolver_get",
                    start,
                    offset,
                    length,
                )
            {
                child.end(start);
            }
        }
    }
    if let Some(child) = run_context {
        child.end(start);
    }
    action.context.span().end_with_timestamp(end);
    true
}

struct TimedSpan {
    context: Context,
    offset: u64,
    end: u64,
}
impl TimedSpan {
    fn end(&self, origin: SystemTime) {
        self.context
            .span()
            .end_with_timestamp(origin + Duration::from_micros(self.end));
    }
}

/// Validate against the selected parent before admitting a child span.
fn timed_child(
    build: &Build,
    parent: &TimedSpan,
    name: &'static str,
    start: SystemTime,
    offset: u64,
    length: u64,
) -> Option<TimedSpan> {
    let end = offset.checked_add(length)?;
    if offset < parent.offset
        || end > parent.end
        || build.admitted.fetch_add(1, Ordering::Relaxed) >= MAX_SPANS
    {
        return None;
    }
    let tracer = build.provider.tracer("build_runner_accelerator.dart");
    Some(TimedSpan {
        context: parent.context.with_span(
            tracer.build_with_context(
                tracer
                    .span_builder(name)
                    .with_start_time(start + Duration::from_micros(offset)),
                &parent.context,
            ),
        ),
        offset,
        end,
    })
}

struct Job {
    spans: Vec<SpanData>,
    done: mpsc::SyncSender<()>,
}
struct ExportSink {
    jobs: mpsc::SyncSender<Job>,
    warnings: mpsc::SyncSender<&'static str>,
}

/// A bounded warning worker may block on stderr; build/export threads only try_send.
fn warning_channel(
    mut output: impl Write + Send + 'static,
) -> Option<mpsc::SyncSender<&'static str>> {
    let (sender, receiver) = mpsc::sync_channel::<&'static str>(1);
    std::thread::Builder::new()
        .name("otel-warning".into())
        .spawn(move || {
            for warning in receiver {
                if writeln!(output, "{warning}").is_err() {
                    break;
                }
            }
        })
        .ok()?;
    Some(sender)
}

fn sink() -> Option<&'static ExportSink> {
    static SINK: OnceLock<Option<ExportSink>> = OnceLock::new();
    SINK.get_or_init(|| {
        let path = std::env::var_os("BUILD_RUNNER_ACCELERATOR_OTEL_FILE")?;
        let warnings = warning_channel(std::io::stderr())?;
        let worker_warnings = warnings.clone();
        let (sender, receiver) = mpsc::sync_channel::<Job>(1);
        std::thread::Builder::new()
            .name("otel-file".into())
            .spawn(move || {
                // Exclusive creation prevents overwrites and opening FIFOs/devices.
                let mut file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(path)
                    .ok();
                if file.is_none() {
                    let _ =
                        worker_warnings.try_send("OTel: cannot create trace file; export disabled");
                }
                let mut bytes = 0;
                for job in receiver {
                    if let Some(output) = &mut file
                        && write_batch(output, &mut bytes, job.spans).is_err()
                    {
                        let _ = worker_warnings
                            .try_send("OTel: trace byte limit or sink failure; export disabled");
                        file = None;
                    }
                    let _ = job.done.try_send(());
                }
            })
            .ok()?;
        Some(ExportSink {
            jobs: sender,
            warnings,
        })
    })
    .as_ref()
}
fn encode(spans: Vec<SpanData>) -> Result<Vec<u8>, serde_json::Error> {
    let resource = opentelemetry_sdk::Resource::builder_empty()
        .with_attribute(KeyValue::new("service.name", "build_runner_accelerator"))
        .build();
    let request = ExportTraceServiceRequest {
        resource_spans: group_spans_by_resource_and_scope(spans, &(&resource).into()),
    };
    let mut data = serde_json::to_vec(&request)?;
    data.push(b'\n');
    Ok(data)
}
fn write_batch(
    mut output: impl Write,
    bytes: &mut usize,
    spans: Vec<SpanData>,
) -> std::io::Result<()> {
    let data = encode(spans).map_err(std::io::Error::other)?;
    if data.len() > MAX_BYTES.saturating_sub(*bytes) {
        return Err(std::io::Error::other("trace byte limit"));
    }
    output.write_all(&data)?;
    *bytes += data.len();
    Ok(())
}

fn export(spans: Vec<SpanData>) {
    let Some(sink) = sink() else { return };
    submit(sink, spans);
}
fn submit(sink: &ExportSink, spans: Vec<SpanData>) {
    let (done, completed) = mpsc::sync_channel(1);
    if sink.jobs.try_send(Job { spans, done }).is_ok() {
        // Bound the entire build-end IO wait, including an unavailable sink.
        if completed.recv_timeout(Duration::from_millis(100)).is_err() {
            let _ = sink
                .warnings
                .try_send("OTel: export pending; trace may be incomplete");
        }
    } else {
        let _ = sink
            .warnings
            .try_send("OTel: export queue full or disconnected; trace dropped");
    }
}

/// Workspace counters can survive multiple operations; attach only this scope's delta.
pub(crate) struct WorkspaceReads<'a> {
    workspace: &'a crate::workspace::Workspace,
    before: crate::workspace::WorkspaceReadMetrics,
    context: Context,
}
impl<'a> WorkspaceReads<'a> {
    pub(crate) fn new(workspace: &'a crate::workspace::Workspace) -> Option<Self> {
        enabled().then(|| Self {
            workspace,
            before: workspace.read_metrics(),
            context: Context::current(),
        })
    }
}
impl Drop for WorkspaceReads<'_> {
    fn drop(&mut self) {
        let after = self.workspace.read_metrics();
        self.context.span().set_attributes([
            KeyValue::new(
                "cache.read.hits",
                after
                    .asset_read_cache_hits
                    .saturating_sub(self.before.asset_read_cache_hits) as i64,
            ),
            KeyValue::new(
                "cache.read.misses",
                after
                    .asset_read_cache_misses
                    .saturating_sub(self.before.asset_read_cache_misses) as i64,
            ),
        ]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn build() -> Build {
        let buffer = Buffer::default();
        let provider = SdkTracerProvider::builder()
            .with_sampler(opentelemetry_sdk::trace::Sampler::AlwaysOn)
            .with_span_processor(buffer.clone())
            .build();
        let root = Context::new().with_span(
            provider
                .tracer("test")
                .start_with_context("native_build", &Context::new()),
        );
        Build {
            provider,
            buffer,
            root,
            admitted: AtomicUsize::new(0),
            reports: AtomicUsize::new(0),
            rejected_reports: AtomicUsize::new(0),
            pending_reports: Mutex::new(BTreeMap::new()),
        }
    }
    #[test]
    fn parallel_context_and_early_return_close_spans() {
        let build = build();
        let root = build.root.clone().attach();
        let phase = Interval::in_build("phase", &build).unwrap();
        let parent = phase.context.span().span_context().span_id();
        std::thread::scope(|scope| {
            for _ in 0..4 {
                let build = &build;
                let context = Context::current();
                scope.spawn(move || {
                    let _guard = context.attach();
                    let fail = || -> Result<(), ()> {
                        let _span = Interval::in_build("worker_batch", build).unwrap();
                        Err(())
                    };
                    assert!(fail().is_err());
                });
            }
        });
        drop(phase);
        drop(root);
        let spans = build.buffer.0.lock().unwrap();
        assert_eq!(spans.len(), 5);
        for span in &spans[..4] {
            assert_eq!(span.parent_span_id, parent);
            assert!(span.start_time <= span.end_time);
            assert!(span.end_time <= spans[4].end_time);
        }
    }
    #[test]
    fn admission_bounds_buffer_and_fresh_build_resets_budget() {
        let build = build();
        for _ in 0..MAX_SPANS + 2 {
            drop(Interval::in_build("test", &build));
        }
        assert_eq!(build.buffer.0.lock().unwrap().len(), MAX_SPANS);
        assert_eq!(build.admitted.load(Ordering::Relaxed), MAX_SPANS + 2);
        let next = self::build();
        assert!(Interval::in_build("test", &next).is_some());
        assert_ne!(
            next.root.span().span_context().trace_id(),
            build.root.span().span_context().trace_id()
        );
    }
    #[test]
    fn worker_bridge_preserves_parent_timestamps_status_and_privacy() {
        let build = build();
        let sc = build.root.span().span_context().clone();
        let (traceparent, id) = issue_report(&build, &sc).unwrap();
        let report = serde_json::json!({"traceparent": traceparent, "otel_report_id": id, "start_us": 1000000, "duration_us": 100,
            "run_builder_start_us": 10, "run_builder_us": 80, "resolver_get_us": 20,
            "resolver_spans": [{"offset_us": 20, "duration_us": 20}], "success": false,
            "input": "/secret/source.dart", "options": "secret"});
        record_worker_report(&build, &report);
        let spans = build.buffer.0.lock().unwrap().clone();
        assert_eq!(spans.len(), 3);
        let action = spans.iter().find(|s| s.name == "dart.action").unwrap();
        let run = spans.iter().find(|s| s.name == "dart.run_builder").unwrap();
        let resolver = spans
            .iter()
            .find(|s| s.name == "dart.resolver_get")
            .unwrap();
        assert_eq!(action.parent_span_id, sc.span_id());
        assert_eq!(run.parent_span_id, action.span_context.span_id());
        assert_eq!(resolver.parent_span_id, run.span_context.span_id());
        assert_eq!(
            action
                .end_time
                .duration_since(action.start_time)
                .unwrap()
                .as_micros(),
            100
        );
        assert!(matches!(action.status, Status::Error { .. }));
        let json = String::from_utf8(encode(spans).unwrap()).unwrap();
        assert!(!json.contains("secret"));
        let json: Value = serde_json::from_str(&json).unwrap();
        assert!(json["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["traceId"].is_string());
    }
    #[test]
    fn invalid_worker_reports_and_sink_failures_are_bounded() {
        let build = build();
        for value in [
            "",
            "00-00000000000000000000000000000000-0000000000000000-01",
            "bad",
        ] {
            record_worker_report(&build, &serde_json::json!({"traceparent": value}));
        }
        assert!(build.buffer.0.lock().unwrap().is_empty());
        let mut bytes = MAX_BYTES;
        let mut out = Vec::new();
        assert!(write_batch(&mut out, &mut bytes, vec![]).is_err());
        assert!(out.is_empty());
        struct Broken;
        impl Write for Broken {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        assert!(write_batch(Broken, &mut 0, vec![]).is_err());
    }
    #[test]
    fn stalled_and_full_export_queue_do_not_block_builds() {
        let (sender, receiver) = mpsc::sync_channel(1);
        let (warnings, _warning_receiver) = mpsc::sync_channel(1);
        let sink = ExportSink {
            jobs: sender,
            warnings,
        };
        let started = std::time::Instant::now();
        submit(&sink, vec![]);
        assert!(started.elapsed() < Duration::from_secs(1));
        let started = std::time::Instant::now();
        submit(&sink, vec![]);
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(receiver);
        submit(&sink, vec![]);
    }
    fn action_report(build: &Build) -> Value {
        let parent = build.root.span().span_context().clone();
        let (traceparent, id) = issue_report(build, &parent).unwrap();
        serde_json::json!({
            "traceparent": traceparent, "otel_report_id": id,
            "start_us": 1000000, "duration_us": 100,
            "run_builder_start_us": 10, "run_builder_us": 80,
            "resolver_spans": [{"offset_us": 20, "duration_us": 20}], "success": true
        })
    }

    #[test]
    fn duplicate_and_unsolicited_reports_cannot_spend_publication_budget() {
        let build = build();
        let first = action_report(&build);
        let second = action_report(&build);
        assert_eq!(first["traceparent"], second["traceparent"]);
        assert_ne!(first["otel_report_id"], second["otel_report_id"]);
        build.admitted.store(MAX_SPANS - 7, Ordering::Relaxed);
        record_worker_report(&build, &first);
        for _ in 0..100 {
            record_worker_report(&build, &first);
        }
        let mut unknown = second.clone();
        unknown["otel_report_id"] = Value::from(999);
        record_worker_report(&build, &unknown);
        let mut forged = second.clone();
        forged["traceparent"] =
            Value::String(format!("00-{}-{}-01", TraceId::from(1), SpanId::from(1)));
        record_worker_report(&build, &forged);
        record_worker_report(&build, &second);
        assert!(build.pending_reports.lock().unwrap().is_empty());
        assert_eq!(build.rejected_reports.load(Ordering::Relaxed), 102);
        assert_eq!(build.buffer.0.lock().unwrap().len(), 6);
        assert!(Interval::in_build("commit", &build).is_some());
        assert_eq!(build.admitted.load(Ordering::Relaxed), MAX_SPANS);
    }

    #[test]
    fn malformed_reports_consume_tickets_and_issued_tickets_are_bounded() {
        let build = build();
        let valid = action_report(&build);
        let mut malformed = valid.clone();
        malformed["duration_us"] = Value::from(u64::MAX);
        record_worker_report(&build, &malformed);
        record_worker_report(&build, &valid);
        assert_eq!(build.rejected_reports.load(Ordering::Relaxed), 2);
        assert_eq!(build.admitted.load(Ordering::Relaxed), 0);
        let parent = build.root.span().span_context().clone();
        for _ in 1..MAX_REPORTS {
            assert!(issue_report(&build, &parent).is_some());
        }
        assert!(issue_report(&build, &parent).is_none());
        assert_eq!(build.pending_reports.lock().unwrap().len(), MAX_REPORTS - 1);
    }

    #[test]
    fn resolver_samples_must_fit_the_selected_parent_before_admission() {
        let build = build();
        let mut report = action_report(&build);
        report["resolver_spans"] = serde_json::json!([
            {"offset_us": 5, "duration_us": 1},
            {"offset_us": 89, "duration_us": 2},
            {"offset_us": u64::MAX, "duration_us": 1},
            {"offset_us": 10, "duration_us": 80}
        ]);
        record_worker_report(&build, &report);
        assert_eq!(build.admitted.load(Ordering::Relaxed), 3);
        let spans = build.buffer.0.lock().unwrap();
        let resolver = spans
            .iter()
            .find(|span| span.name == "dart.resolver_get")
            .unwrap();
        let run = spans
            .iter()
            .find(|span| span.name == "dart.run_builder")
            .unwrap();
        assert_eq!(resolver.start_time, run.start_time);
        assert_eq!(resolver.end_time, run.end_time);
        drop(spans);
        // Without a builder interval, the selected parent is the whole action.
        let mut fallback = action_report(&build);
        fallback
            .as_object_mut()
            .unwrap()
            .remove("run_builder_start_us");
        fallback["resolver_spans"] = serde_json::json!([{"offset_us": 0, "duration_us": 100}]);
        record_worker_report(&build, &fallback);
        let spans = build.buffer.0.lock().unwrap();
        let action = spans.last().unwrap();
        let resolver = &spans[spans.len() - 2];
        assert_eq!(resolver.parent_span_id, action.span_context.span_id());
        assert_eq!(resolver.start_time, action.start_time);
        assert_eq!(resolver.end_time, action.end_time);
    }

    #[test]
    fn encoding_preserves_rust_and_dart_scope_metadata() {
        let build = build();
        let scope = opentelemetry::InstrumentationScope::builder("native-test")
            .with_version("1.2.3")
            .with_schema_url("https://example.invalid/schema")
            .with_attributes([KeyValue::new("component", "native")])
            .build();
        let mut native = build
            .provider
            .tracer_with_scope(scope)
            .start_with_context("phase", &build.root);
        native.end();
        record_worker_report(&build, &action_report(&build));
        let data = encode(build.buffer.0.lock().unwrap().clone()).unwrap();
        let request: Value = serde_json::from_slice(&data).unwrap();
        let scopes = request["resourceSpans"][0]["scopeSpans"]
            .as_array()
            .unwrap();
        assert_eq!(scopes.len(), 2);
        let native = scopes
            .iter()
            .find(|scope| scope["scope"]["name"] == "native-test")
            .unwrap();
        assert_eq!(native["scope"]["version"], "1.2.3");
        assert_eq!(native["schemaUrl"], "https://example.invalid/schema");
        assert_eq!(native["scope"]["attributes"][0]["key"], "component");
        assert_eq!(native["spans"][0]["name"], "phase");
        let dart = scopes
            .iter()
            .find(|scope| scope["scope"]["name"] == "build_runner_accelerator.dart")
            .unwrap();
        assert_eq!(dart["spans"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn blocked_stderr_and_saturated_warning_queue_do_not_block_submit() {
        struct BlockedStderr {
            started: mpsc::SyncSender<()>,
            release: mpsc::Receiver<()>,
        }
        impl Write for BlockedStderr {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                let _ = self.started.try_send(());
                let _ = self.release.recv();
                Err(std::io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let (started, writing) = mpsc::sync_channel(1);
        let (release, blocked) = mpsc::channel();
        let warnings = warning_channel(BlockedStderr {
            started,
            release: blocked,
        })
        .unwrap();
        warnings.try_send("block warning writer").unwrap();
        writing.recv_timeout(Duration::from_secs(1)).unwrap();
        warnings.try_send("fill warning queue").unwrap();
        let (sender, receiver) = mpsc::sync_channel(1);
        let sink = ExportSink {
            jobs: sender,
            warnings,
        };
        let started = std::time::Instant::now();
        submit(&sink, vec![]); // stalled job, warning queue full
        submit(&sink, vec![]); // export queue full, warning queue full
        drop(receiver);
        submit(&sink, vec![]); // disconnected export, warning queue full
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(release);
    }

    #[test]
    fn wall_span_retains_interval_until_drop() {
        const CHILD: &str = "BUILD_RUNNER_ACCELERATOR_TEST_WALL_BRIDGE";
        if std::env::var_os(CHILD).is_some() {
            let session = crate::wall::Session::new();
            let build = ACTIVE.lock().unwrap().clone().unwrap();
            let span = crate::wall::Span::new("wall_bridge_test");
            assert!(build.buffer.0.lock().unwrap().is_empty());
            assert!(Context::current().span().is_recording());
            drop(span);
            let records = build.buffer.0.lock().unwrap();
            assert_eq!(records.len(), 1);
            assert_eq!(records[0].name, "wall_bridge_test");
            drop(records);
            session.finish(true);
            drop(session);
            return;
        }
        // Isolate cached opt-in state without mutating the multi-threaded test environment.
        let path = std::env::temp_dir().join(format!(
            "otel-wall-{}-{}.ndjson",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "telemetry::tests::wall_span_retains_interval_until_drop",
            ])
            .env(CHILD, "1")
            .env("BUILD_RUNNER_ACCELERATOR_OTEL_FILE", &path)
            .status()
            .unwrap();
        assert!(status.success());
        let bytes = std::fs::read(&path).unwrap();
        std::fs::remove_file(path).unwrap();
        let request: Value = serde_json::from_slice(&bytes).unwrap();
        let spans = request["resourceSpans"][0]["scopeSpans"][0]["spans"]
            .as_array()
            .unwrap();
        assert!(spans.iter().any(|span| span["name"] == "wall_bridge_test"));
        assert!(spans.iter().any(|span| span["name"] == "native_build"));
    }
}
