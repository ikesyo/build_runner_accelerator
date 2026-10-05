//! Opt-in frontend intervals. Every timestamp uses one Rust-process Instant.
//! Buffer events until the build ends so stderr writes do not stall dispatch.
use serde::Serialize;
use std::io::{self, BufWriter, Write};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

const MAX_EVENTS: usize = 100_000;
static ACTIVE: Mutex<Option<Arc<Recorder>>> = Mutex::new(None);

fn enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED
        .get_or_init(|| std::env::var("BUILD_RUNNER_ACCELERATOR_WALL_TRACE").as_deref() == Ok("1"))
}

struct Recorder {
    origin: Instant,
    events: Mutex<(Vec<Event>, usize)>,
}

#[derive(Serialize)]
struct Event {
    stage: &'static str,
    start_us: u128,
    end_us: u128,
    thread: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    phase: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    builder: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    worker_pid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    batch_id: Option<u64>,
}

/// One session per native build (including no-op/error), or watch iteration.
/// A nested session shares the outer recorder and does not flush it.
pub(crate) struct Session(Option<Arc<Recorder>>);

impl Session {
    pub(crate) fn new() -> Self {
        if !enabled() {
            return Self(None);
        }
        let mut active = ACTIVE.lock().unwrap();
        if active.is_some() {
            return Self(None);
        }
        let recorder = Arc::new(Recorder {
            origin: Instant::now(),
            events: Mutex::new((Vec::new(), 0)),
        });
        *active = Some(recorder.clone());
        Self(Some(recorder))
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let Some(recorder) = &self.0 else { return };
        let end_us = recorder.origin.elapsed().as_micros();
        *ACTIVE.lock().unwrap() = None;
        let (events, dropped) = &mut *recorder.events.lock().unwrap();
        events.sort_by_key(|event| (event.start_us, event.end_us));
        // A diagnostic sink failure must not panic in Drop or replace a build
        // error. A partial trace lacks its terminal root and is rejected by
        // the analyzer. Hold stderr once, after all worker threads have joined.
        let _ = write_trace(io::stderr().lock(), events, *dropped, end_us);
    }
}

fn write_trace(
    writer: impl Write,
    events: &[Event],
    dropped: usize,
    end_us: u128,
) -> io::Result<()> {
    let mut writer = BufWriter::new(writer);
    for event in events {
        write!(writer, "Rust wall trace: ")?;
        serde_json::to_writer(&mut writer, event).map_err(io::Error::other)?;
        writeln!(writer)?;
    }
    write!(writer, "Rust wall trace: ")?;
    serde_json::to_writer(
        &mut writer,
        &serde_json::json!({
            "stage": "native_build", "start_us": 0, "end_us": end_us,
            "pid": std::process::id(), "dropped_events": dropped,
        }),
    )
    .map_err(io::Error::other)?;
    writeln!(writer)?;
    writer.flush()
}

pub(crate) struct Span(Option<(Arc<Recorder>, Event)>);

impl Span {
    pub(crate) fn new(stage: &'static str) -> Self {
        if !enabled() {
            return Self(None);
        }
        let recorder = ACTIVE.lock().unwrap().clone();
        Self(recorder.map(|recorder| {
            let event = Event {
                stage,
                start_us: recorder.origin.elapsed().as_micros(),
                end_us: 0,
                thread: format!("{:?}", std::thread::current().id()),
                phase: None,
                builder: None,
                worker_pid: None,
                batch_id: None,
            };
            (recorder, event)
        }))
    }

    pub(crate) fn phase(mut self, phase: u32, builder: &str) -> Self {
        if let Some((_, event)) = &mut self.0 {
            event.phase = Some(phase);
            event.builder = Some(builder.to_owned());
        }
        self
    }

    pub(crate) fn worker(mut self, pid: u32, batch_id: Option<u64>) -> Self {
        if let Some((_, event)) = &mut self.0 {
            event.worker_pid = Some(pid);
            event.batch_id = batch_id;
        }
        self
    }
}

impl Drop for Span {
    fn drop(&mut self) {
        let Some((recorder, mut event)) = self.0.take() else {
            return;
        };
        event.end_us = recorder.origin.elapsed().as_micros();
        let (events, dropped) = &mut *recorder.events.lock().unwrap();
        if events.len() < MAX_EVENTS {
            events.push(event);
        } else {
            *dropped += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn span(recorder: &Arc<Recorder>) -> Span {
        Span(Some((
            recorder.clone(),
            Event {
                stage: "test",
                start_us: recorder.origin.elapsed().as_micros(),
                end_us: 0,
                thread: format!("{:?}", std::thread::current().id()),
                phase: None,
                builder: None,
                worker_pid: None,
                batch_id: None,
            },
        )))
    }

    #[test]
    fn concurrent_and_error_spans_share_origin_and_close() {
        let recorder = Arc::new(Recorder {
            origin: Instant::now(),
            events: Mutex::new((Vec::new(), 0)),
        });
        let parent = span(&recorder);
        std::thread::scope(|scope| {
            for pid in 1..=4 {
                let recorder = &recorder;
                scope.spawn(move || {
                    let fail = || -> Result<(), ()> {
                        let _span = span(recorder).worker(pid, Some(9)).phase(2, "builder");
                        Err(())
                    };
                    assert!(fail().is_err());
                });
            }
        });
        drop(parent);
        let events = recorder.events.lock().unwrap();
        assert_eq!(events.0.len(), 5);
        let parent = events.0.last().unwrap();
        for child in &events.0[..4] {
            assert!(parent.start_us <= child.start_us);
            assert!(child.start_us <= child.end_us);
            assert!(child.end_us <= parent.end_us);
            assert_eq!(child.batch_id, Some(9));
            assert_eq!(child.phase, Some(2));
        }
        assert_eq!(events.1, 0);
    }

    #[test]
    fn trace_cap_reports_missing_intervals() {
        let recorder = Arc::new(Recorder {
            origin: Instant::now(),
            events: Mutex::new((Vec::new(), 0)),
        });
        for _ in 0..MAX_EVENTS + 2 {
            drop(span(&recorder));
        }
        let events = recorder.events.lock().unwrap();
        assert_eq!(events.0.len(), MAX_EVENTS);
        assert_eq!(events.1, 2);
    }

    #[test]
    fn trace_sink_failure_returns_error_without_panicking() {
        struct BrokenSink;
        impl Write for BrokenSink {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed stderr"))
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        assert!(write_trace(BrokenSink, &[], 0, 10).is_err());
    }
}
