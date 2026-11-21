//! Single-package in-process transport, enabled only in the spike library.

use crate::worker::WorkerConnection;
use std::collections::{HashMap, VecDeque};
use std::io::{self, Cursor, Read, Write};
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

type HostNotification = extern "C" fn(i32, u64);
type WorkerNotification = extern "C" fn();

struct Bridge {
    notify: HostNotification,
    workers: Mutex<HashMap<u64, Arc<Worker>>>,
    next_worker: AtomicU64,
    profile: bool,
}

#[derive(Default)]
struct WorkerOutput {
    frames: VecDeque<QueuedFrame>,
    notify: Option<WorkerNotification>,
    finished: bool,
    detached: bool,
}

struct QueuedFrame {
    bytes: Box<[u8]>,
    queued: Option<Instant>,
}

#[derive(Default)]
struct QueueMetrics {
    frames: AtomicU64,
    wait_us: AtomicU64,
}

impl QueueMetrics {
    fn record(&self, queued: Option<Instant>) {
        if let Some(queued) = queued {
            self.frames.fetch_add(1, Ordering::Relaxed);
            self.wait_us
                .fetch_add(queued.elapsed().as_micros() as u64, Ordering::Relaxed);
        }
    }

    fn snapshot(&self) -> (u64, u64) {
        (
            self.frames.load(Ordering::Relaxed),
            self.wait_us.load(Ordering::Relaxed),
        )
    }
}

struct Worker {
    outgoing: Mutex<WorkerOutput>,
    incoming: Mutex<Option<Sender<QueuedFrame>>>,
    profile: bool,
    to_dart: QueueMetrics,
    to_rust: QueueMetrics,
}

static BRIDGE: OnceLock<Bridge> = OnceLock::new();

fn worker(id: u64) -> Option<Arc<Worker>> {
    BRIDGE.get()?.workers.lock().unwrap().get(&id).cloned()
}

// The reset probe starts the pool before the first phase produces an overlay.
pub(crate) fn eager_workers_for_reset_probe() -> bool {
    BRIDGE.get().is_some()
        && std::env::var("BUILD_RUNNER_ACCELERATOR_FFI_RESET_PROBE").as_deref() == Ok("1")
}

pub(crate) fn connect() -> io::Result<Option<WorkerConnection>> {
    let Some(bridge) = BRIDGE.get() else {
        return Ok(None);
    };
    let (sender, receiver) = mpsc::channel();
    let worker = Arc::new(Worker {
        outgoing: Mutex::default(),
        incoming: Mutex::new(Some(sender)),
        profile: bridge.profile,
        to_dart: QueueMetrics::default(),
        to_rust: QueueMetrics::default(),
    });
    let id = bridge.next_worker.fetch_add(1, Ordering::Relaxed);
    bridge.workers.lock().unwrap().insert(id, worker.clone());
    (bridge.notify)(1, id);
    Ok(Some(WorkerConnection::in_process(
        id,
        FrameOutput {
            worker: worker.clone(),
            buffer: Vec::new(),
        },
        FrameInput {
            worker,
            receiver,
            current: Cursor::new(Box::default()),
        },
    )))
}

struct FrameOutput {
    worker: Arc<Worker>,
    buffer: Vec<u8>,
}

impl Write for FrameOutput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.buffer.write(bytes)
    }

    fn flush(&mut self) -> io::Result<()> {
        if self.buffer.is_empty() {
            return Ok(());
        }
        let mut output = self.worker.outgoing.lock().unwrap();
        if output.detached {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "Dart isolate exited",
            ));
        }
        output.frames.push_back(QueuedFrame {
            bytes: std::mem::take(&mut self.buffer).into_boxed_slice(),
            queued: self.worker.profile.then(Instant::now),
        });
        if let Some(notify) = output.notify {
            notify();
        }
        Ok(())
    }
}

impl Drop for FrameOutput {
    fn drop(&mut self) {
        let mut output = self.worker.outgoing.lock().unwrap();
        output.finished = true;
        if let Some(notify) = output.notify {
            notify();
        }
    }
}

struct FrameInput {
    worker: Arc<Worker>,
    receiver: Receiver<QueuedFrame>,
    current: Cursor<Box<[u8]>>,
}

impl Read for FrameInput {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        if bytes.is_empty() {
            return Ok(0);
        }
        if self.current.position() == self.current.get_ref().len() as u64 {
            let Ok(frame) = self.receiver.recv() else {
                return Ok(0);
            };
            self.worker.to_rust.record(frame.queued);
            self.current = Cursor::new(frame.bytes);
        }
        self.current.read(bytes)
    }
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_alloc(length: usize) -> *mut u8 {
    Box::into_raw(vec![0; length].into_boxed_slice()).cast()
}

// The Dart caller transfers ownership of a buffer returned by bra_spike_alloc.
unsafe fn take_buffer(data: *mut u8, length: usize) -> Box<[u8]> {
    unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(data, length)) }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn bra_spike_free(data: *mut u8, length: usize) {
    drop(unsafe { take_buffer(data, length) });
}

#[unsafe(no_mangle)]
unsafe extern "C" fn bra_spike_start(
    args: *mut u8,
    length: usize,
    notify: HostNotification,
) -> i32 {
    let args = unsafe { take_buffer(args, length) };
    let Ok(args) = serde_json::from_slice::<Vec<String>>(&args) else {
        return 1;
    };
    if BRIDGE
        .set(Bridge {
            notify,
            workers: Mutex::default(),
            next_worker: AtomicU64::new(1),
            profile: std::env::var("BUILD_RUNNER_ACCELERATOR_METRICS").as_deref() == Ok("1"),
        })
        .is_err()
    {
        return 1;
    }
    let engine = std::thread::Builder::new()
        .name("bra-spike".to_owned())
        .spawn(move || {
            let result = std::panic::catch_unwind(|| crate::run(args.into_iter(), true));
            let event = match result {
                Ok(Ok(())) => 2,
                Ok(Err(error)) => {
                    eprintln!("build_runner_accelerator: {error}");
                    3
                }
                Err(_) => 3,
            };
            notify(event, 0);
        });
    i32::from(engine.is_err())
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_attach(id: u64, notify: WorkerNotification) -> i32 {
    let Some(worker) = worker(id) else {
        return 1;
    };
    let mut output = worker.outgoing.lock().unwrap();
    if output.detached || output.notify.is_some() {
        return 1;
    }
    output.notify = Some(notify);
    0
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_detach(id: u64) {
    let Some(bridge) = BRIDGE.get() else { return };
    // Keep the registry locked until the notification is disarmed. If the
    // host and isolate detach concurrently, either can then close its port.
    let mut workers = bridge.workers.lock().unwrap();
    if let Some(worker) = workers.remove(&id) {
        let mut output = worker.outgoing.lock().unwrap();
        output.detached = true;
        output.notify = None;
        output.frames.clear();
        worker.incoming.lock().unwrap().take();
        if worker.profile {
            let (to_dart_frames, to_dart_wait_us) = worker.to_dart.snapshot();
            let (to_rust_frames, to_rust_wait_us) = worker.to_rust.snapshot();
            let line = format!(
                "FFI queues: worker={id} to_dart_frames={to_dart_frames} to_dart_wait_us={to_dart_wait_us} to_rust_frames={to_rust_frames} to_rust_wait_us={to_rust_wait_us}\n"
            );
            let _ = io::stderr().write_all(line.as_bytes());
        }
    }
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_take(id: u64) -> *mut u8 {
    let Some(worker) = worker(id) else {
        return ptr::null_mut();
    };
    let mut output = worker.outgoing.lock().unwrap();
    output.frames.pop_front().map_or(ptr::null_mut(), |frame| {
        worker.to_dart.record(frame.queued);
        Box::into_raw(frame.bytes).cast()
    })
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_finished(id: u64) -> i32 {
    i32::from(worker(id).is_none_or(|worker| {
        let output = worker.outgoing.lock().unwrap();
        output.finished && output.frames.is_empty()
    }))
}

#[unsafe(no_mangle)]
unsafe extern "C" fn bra_spike_send(id: u64, data: *mut u8, length: usize) -> i32 {
    let frame = unsafe { take_buffer(data, length) };
    let sent = worker(id).is_some_and(|worker| {
        worker
            .incoming
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|sender| {
                sender
                    .send(QueuedFrame {
                        bytes: frame,
                        queued: worker.profile.then(Instant::now),
                    })
                    .is_ok()
            })
    });
    i32::from(!sent)
}
