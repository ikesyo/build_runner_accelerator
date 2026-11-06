//! Opt-in OTel bridge for existing wall intervals and worker timing reports.
//! A bounded build buffer and one bounded export queue keep disk IO off builders.
use opentelemetry::trace::{
    Span as _, SpanContext, SpanId, Status, TraceContextExt, TraceFlags, TraceId, TraceState,
    Tracer, TracerProvider,
};
use opentelemetry::{Context, ContextGuard, KeyValue};
use opentelemetry_proto::tonic::{
    collector::trace::v1::ExportTraceServiceRequest,
    trace::v1::{ResourceSpans, ScopeSpans},
};
use opentelemetry_sdk::{
    error::OTelSdkResult,
    trace::{SdkTracerProvider, Span, SpanData, SpanProcessor},
};
use serde_json::Value;
use std::{
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
            build.reports.load(Ordering::Relaxed).saturating_sub(2048) as i64,
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

pub(crate) fn traceparent() -> Option<String> {
    if !enabled() {
        return None;
    }
    let build = ACTIVE.lock().unwrap().clone()?;
    let current = Context::current();
    let parent = &current.get::<IpcParent>()?.0;
    if build.reports.fetch_add(1, Ordering::Relaxed) >= 2048 {
        return None;
    }
    Some(format!("00-{}-{}-01", parent.trace_id(), parent.span_id()))
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
    let Some(context) = message
        .get("traceparent")
        .and_then(Value::as_str)
        .and_then(parent)
    else {
        return;
    };
    if context.span().span_context().trace_id() != build.root.span().span_context().trace_id() {
        return;
    }
    let Some(start) = message
        .get("start_us")
        .and_then(Value::as_u64)
        .and_then(|us| UNIX_EPOCH.checked_add(Duration::from_micros(us)))
    else {
        return;
    };
    let Some(duration) = message
        .get("duration_us")
        .and_then(Value::as_u64)
        .filter(|us| *us <= 86_400_000_000)
    else {
        return;
    };
    let Some(end) = start.checked_add(Duration::from_micros(duration)) else {
        return;
    };
    if build.admitted.fetch_add(1, Ordering::Relaxed) >= MAX_SPANS {
        return;
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
    let action = context.with_span(span);
    let run = message
        .get("run_builder_start_us")
        .and_then(Value::as_u64)
        .zip(message.get("run_builder_us").and_then(Value::as_u64));
    let mut run_context = None;
    if let Some((offset, length)) = run {
        run_context = timed_child(
            build,
            &action,
            "dart.run_builder",
            start,
            duration,
            offset,
            length,
        );
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
                    duration,
                    offset,
                    length,
                )
            {
                child
                    .span()
                    .end_with_timestamp(start + Duration::from_micros(offset + length));
            }
        }
    }
    if let (Some(child), Some((offset, length))) = (run_context, run) {
        child
            .span()
            .end_with_timestamp(start + Duration::from_micros(offset + length));
    }
    action.span().end_with_timestamp(end);
}

#[allow(clippy::too_many_arguments)]
fn timed_child(
    build: &Build,
    parent: &Context,
    name: &'static str,
    start: SystemTime,
    duration: u64,
    offset: u64,
    length: u64,
) -> Option<Context> {
    if offset.checked_add(length)? > duration
        || build.admitted.fetch_add(1, Ordering::Relaxed) >= MAX_SPANS
    {
        return None;
    }
    let tracer = build.provider.tracer("build_runner_accelerator.dart");
    Some(
        parent.with_span(
            tracer.build_with_context(
                tracer
                    .span_builder(name)
                    .with_start_time(start + Duration::from_micros(offset)),
                parent,
            ),
        ),
    )
}

struct Job {
    spans: Vec<SpanData>,
    done: mpsc::SyncSender<()>,
}
fn sink() -> Option<&'static mpsc::SyncSender<Job>> {
    static SINK: OnceLock<Option<mpsc::SyncSender<Job>>> = OnceLock::new();
    SINK.get_or_init(|| {
        let path = std::env::var_os("BUILD_RUNNER_ACCELERATOR_OTEL_FILE")?;
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
                    eprintln!("OTel: cannot create trace file; export disabled");
                }
                let mut bytes = 0;
                for job in receiver {
                    if let Some(output) = &mut file
                        && write_batch(output, &mut bytes, job.spans).is_err()
                    {
                        eprintln!("OTel: trace byte limit or sink failure; export disabled");
                        file = None;
                    }
                    let _ = job.done.try_send(());
                }
            })
            .ok()?;
        Some(sender)
    })
    .as_ref()
}
fn encode(spans: Vec<SpanData>) -> Result<Vec<u8>, serde_json::Error> {
    use opentelemetry_proto::tonic::{
        common::v1::{AnyValue, KeyValue as ProtoKeyValue, any_value},
        resource::v1::Resource,
    };
    let request = ExportTraceServiceRequest {
        resource_spans: vec![ResourceSpans {
            resource: Some(Resource {
                attributes: vec![ProtoKeyValue {
                    key: "service.name".into(),
                    value: Some(AnyValue {
                        value: Some(any_value::Value::StringValue(
                            "build_runner_accelerator".into(),
                        )),
                    }),
                }],
                ..Default::default()
            }),
            scope_spans: vec![ScopeSpans {
                scope: Some(
                    opentelemetry_proto::tonic::common::v1::InstrumentationScope {
                        name: "build_runner_accelerator".into(),
                        version: env!("CARGO_PKG_VERSION").into(),
                        ..Default::default()
                    },
                ),
                spans: spans.into_iter().map(Into::into).collect(),
                ..Default::default()
            }],
            ..Default::default()
        }],
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
fn submit(sink: &mpsc::SyncSender<Job>, spans: Vec<SpanData>) {
    let (done, completed) = mpsc::sync_channel(1);
    if sink.try_send(Job { spans, done }).is_ok() {
        // Bound the entire build-end IO wait, including an unavailable sink.
        if completed.recv_timeout(Duration::from_millis(100)).is_err() {
            eprintln!("OTel: export pending; trace may be incomplete");
        }
    } else {
        eprintln!("OTel: export queue full; trace dropped");
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
        let report = serde_json::json!({"traceparent": format!("00-{}-{}-01", sc.trace_id(), sc.span_id()), "start_us": 1000000, "duration_us": 100,
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
        let started = std::time::Instant::now();
        submit(&sender, vec![]);
        assert!(started.elapsed() < Duration::from_secs(1));
        let started = std::time::Instant::now();
        submit(&sender, vec![]);
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(receiver);
        submit(&sender, vec![]);
    }
}
