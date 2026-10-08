//! Unix process-group supervision also covers manifest/probe/compiler children.
//! Detached prewarm deliberately owns a different session and survives the hook.
pub(crate) const SUPERVISION_CONTEXT: &str = "BUILD_RUNNER_ACCELERATOR_SUPERVISED";

#[cfg(unix)]
pub(crate) fn supervise() -> std::io::Result<Option<i32>> {
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::process::Command;
    use std::sync::atomic::{AtomicI32, Ordering};
    use std::time::{Duration, Instant};

    const CHILD_MARKER: &str = SUPERVISION_CONTEXT;
    static SIGNAL: AtomicI32 = AtomicI32::new(0);
    extern "C" fn received(signal: i32) {
        SIGNAL.store(signal, Ordering::Relaxed);
    }
    unsafe extern "C" {
        fn signal(signal: i32, handler: usize) -> usize;
        fn kill(pid: i32, signal: i32) -> i32;
    }
    if std::env::var_os(CHILD_MARKER).is_some() {
        // Internal helpers inherit this group instead of creating a new one.
        // Stock and explicitly detached prewarm clear the context at spawn.
        return Ok(None);
    }
    // Signal handlers only store an atomic; all subprocess work runs here.
    unsafe {
        signal(1, received as *const () as usize);
        signal(2, received as *const () as usize);
        signal(15, received as *const () as usize);
    }
    let mut child = Command::new(std::env::current_exe()?)
        .args(std::env::args_os().skip(1))
        .env(CHILD_MARKER, "1")
        .process_group(0)
        .spawn()?;
    let group = -(child.id() as i32);
    let mut interrupted = None;
    loop {
        let received = SIGNAL.swap(0, Ordering::Relaxed);
        if received != 0 {
            unsafe {
                kill(group, received);
            }
            interrupted.get_or_insert((received, Instant::now()));
        }
        if let Some(status) = child.try_wait()? {
            // Normal success may leave an intentional background AOT compile.
            // Cancellation/failure must stop the entire internal subtree.
            if interrupted.is_some() || !status.success() {
                unsafe {
                    kill(group, 9);
                }
            }
            return Ok(Some(interrupted.map_or_else(
                || {
                    status
                        .code()
                        .unwrap_or_else(|| 128 + status.signal().unwrap_or(1))
                },
                |(signal, _)| 128 + signal,
            )));
        }
        if interrupted.is_some_and(|(_, started)| started.elapsed() > Duration::from_secs(5)) {
            unsafe {
                kill(group, 9);
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(not(any(unix, windows)))]
pub(crate) fn supervise() -> std::io::Result<Option<i32>> {
    Ok(None)
}

/// A Windows job closes the native subtree on exit, including workers started
/// by the Dart generator. Console events get a bounded shutdown window.
#[cfg(windows)]
pub(crate) fn supervise() -> std::io::Result<Option<i32>> {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    use std::os::windows::process::CommandExt;
    use std::process::Command;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};

    const CHILD_MARKER: &str = SUPERVISION_CONTEXT;
    static INTERRUPTED: AtomicBool = AtomicBool::new(false);
    type Handle = *mut c_void;
    #[repr(C)]
    #[derive(Default)]
    struct BasicLimits {
        process_time: i64,
        job_time: i64,
        flags: u32,
        minimum_working_set: usize,
        maximum_working_set: usize,
        active_processes: u32,
        affinity: usize,
        priority: u32,
        scheduling_class: u32,
    }
    #[repr(C)]
    #[derive(Default)]
    struct ExtendedLimits {
        basic: BasicLimits,
        io_counters: [u64; 6],
        process_memory: usize,
        job_memory: usize,
        peak_process_memory: usize,
        peak_job_memory: usize,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateJobObjectW(attributes: Handle, name: *const u16) -> Handle;
        fn SetInformationJobObject(job: Handle, class: i32, info: Handle, size: u32) -> i32;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
        fn CloseHandle(handle: Handle) -> i32;
        fn SetConsoleCtrlHandler(handler: Option<extern "system" fn(u32) -> i32>, add: i32) -> i32;
        fn GenerateConsoleCtrlEvent(event: u32, group: u32) -> i32;
        fn TerminateJobObject(job: Handle, code: u32) -> i32;
        fn CreateEventW(
            attributes: Handle,
            manual_reset: i32,
            initial_state: i32,
            name: *const u16,
        ) -> Handle;
        fn OpenEventW(access: u32, inherit: i32, name: *const u16) -> Handle;
        fn SetEvent(event: Handle) -> i32;
        fn WaitForSingleObject(handle: Handle, milliseconds: u32) -> u32;
    }
    extern "system" fn received(_: u32) -> i32 {
        INTERRUPTED.store(true, Ordering::Relaxed);
        1
    }
    struct Job(Handle);
    impl Drop for Job {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
    if let Some(event_name) = std::env::var_os(CHILD_MARKER) {
        if event_name != "1" {
            use std::os::windows::ffi::OsStrExt;
            let name: Vec<u16> = event_name.encode_wide().chain(Some(0)).collect();
            let event = Job(unsafe { OpenEventW(0x100000, 0, name.as_ptr()) });
            if event.0.is_null() {
                return Err(std::io::Error::last_os_error());
            }
            if unsafe { WaitForSingleObject(event.0, 30_000) } != 0 {
                return Err(std::io::Error::other(
                    "native supervisor readiness timed out",
                ));
            }
            // Future internal helpers already inherit the assigned job.
            unsafe {
                std::env::set_var(CHILD_MARKER, "1");
            }
        }
        unsafe {
            SetConsoleCtrlHandler(None, 0);
        }
        return Ok(None);
    }
    let event_name = format!(
        "Local\\build-runner-accelerator-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    );
    let name: Vec<u16> = event_name.encode_utf16().chain(Some(0)).collect();
    let event = Job(unsafe { CreateEventW(std::ptr::null_mut(), 1, 0, name.as_ptr()) });
    if event.0.is_null() {
        return Err(std::io::Error::last_os_error());
    }
    let job = Job(unsafe { CreateJobObjectW(std::ptr::null_mut(), std::ptr::null()) });
    if job.0.is_null() {
        return Err(std::io::Error::last_os_error());
    }
    let mut limits = ExtendedLimits::default();
    limits.basic.flags = 0x2000 | 0x800; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if unsafe {
        SetInformationJobObject(
            job.0,
            9,
            (&mut limits as *mut ExtendedLimits).cast(),
            std::mem::size_of::<ExtendedLimits>() as u32,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error());
    }
    unsafe {
        SetConsoleCtrlHandler(Some(received), 1);
    }
    let mut child = Command::new(std::env::current_exe()?)
        .args(std::env::args_os().skip(1))
        .env(CHILD_MARKER, event_name)
        .creation_flags(0x200) // CREATE_NEW_PROCESS_GROUP
        .spawn()?;
    if unsafe { AssignProcessToJobObject(job.0, child.as_raw_handle()) } == 0 {
        let error = std::io::Error::last_os_error();
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }
    if unsafe { SetEvent(event.0) } == 0 {
        let error = std::io::Error::last_os_error();
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }
    let mut interrupted = None;
    loop {
        if INTERRUPTED.swap(false, Ordering::Relaxed) {
            unsafe {
                GenerateConsoleCtrlEvent(1, child.id());
            }
            interrupted.get_or_insert(Instant::now());
        }
        if let Some(status) = child.try_wait()? {
            if status.success() && interrupted.is_none() {
                limits.basic.flags &= !0x2000;
                if unsafe {
                    SetInformationJobObject(
                        job.0,
                        9,
                        (&mut limits as *mut ExtendedLimits).cast(),
                        std::mem::size_of::<ExtendedLimits>() as u32,
                    )
                } == 0
                {
                    return Err(std::io::Error::last_os_error());
                }
            }
            return Ok(Some(if interrupted.is_some() {
                130
            } else {
                status.code().unwrap_or(1)
            }));
        }
        if interrupted.is_some_and(|started| started.elapsed() > Duration::from_secs(5)) {
            unsafe {
                TerminateJobObject(job.0, 130);
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
