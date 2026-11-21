//! One-build, one-worker in-process transport, enabled only in the spike library.

use crate::worker::WorkerConnection;
use std::collections::VecDeque;
use std::io::{self, Cursor, Read, Write};
use std::ptr;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};

type HostNotification = extern "C" fn(i32);
type WorkerNotification = extern "C" fn();

struct Bridge {
    notify: HostNotification,
    worker: OnceLock<Worker>,
}

#[derive(Default)]
struct WorkerOutput {
    frames: VecDeque<Box<[u8]>>,
    notify: Option<WorkerNotification>,
    finished: bool,
    detached: bool,
}

struct Worker {
    outgoing: Mutex<WorkerOutput>,
    incoming: Mutex<Option<Sender<Box<[u8]>>>>,
}

static BRIDGE: OnceLock<Bridge> = OnceLock::new();

fn worker() -> Option<&'static Worker> {
    BRIDGE.get()?.worker.get()
}

pub(crate) fn connect() -> io::Result<Option<WorkerConnection>> {
    let Some(bridge) = BRIDGE.get() else {
        return Ok(None);
    };
    let (sender, receiver) = mpsc::channel();
    bridge
        .worker
        .set(Worker {
            outgoing: Mutex::default(),
            incoming: Mutex::new(Some(sender)),
        })
        .map_err(|_| io::Error::other("FFI spike cannot start a second worker"))?;
    let worker = bridge.worker.get().unwrap();
    (bridge.notify)(1);
    Ok(Some(WorkerConnection::in_process(
        FrameOutput {
            worker,
            buffer: Vec::new(),
        },
        FrameInput {
            receiver,
            current: Cursor::new(Box::default()),
        },
    )))
}

struct FrameOutput {
    worker: &'static Worker,
    buffer: Vec<u8>,
}

impl Write for FrameOutput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.buffer.write(bytes)
    }

    fn flush(&mut self) -> io::Result<()> {
        let mut output = self.worker.outgoing.lock().unwrap();
        if output.detached {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "Dart isolate exited",
            ));
        }
        output
            .frames
            .push_back(std::mem::take(&mut self.buffer).into_boxed_slice());
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
    receiver: Receiver<Box<[u8]>>,
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
            self.current = Cursor::new(frame);
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
            worker: OnceLock::new(),
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
            notify(event);
        });
    i32::from(engine.is_err())
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_attach(notify: WorkerNotification) -> i32 {
    let Some(worker) = worker() else {
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
extern "C" fn bra_spike_detach() {
    if let Some(worker) = worker() {
        let mut output = worker.outgoing.lock().unwrap();
        output.detached = true;
        output.notify = None;
        output.frames.clear();
        worker.incoming.lock().unwrap().take();
    }
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_take() -> *mut u8 {
    worker()
        .and_then(|worker| worker.outgoing.lock().unwrap().frames.pop_front())
        .map_or(ptr::null_mut(), |frame| Box::into_raw(frame).cast())
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_finished() -> i32 {
    i32::from(worker().is_some_and(|worker| {
        let output = worker.outgoing.lock().unwrap();
        output.finished && output.frames.is_empty()
    }))
}

#[unsafe(no_mangle)]
unsafe extern "C" fn bra_spike_send(data: *mut u8, length: usize) -> i32 {
    let frame = unsafe { take_buffer(data, length) };
    let sent = worker().is_some_and(|worker| {
        worker
            .incoming
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|sender| sender.send(frame).is_ok())
    });
    i32::from(!sent)
}
