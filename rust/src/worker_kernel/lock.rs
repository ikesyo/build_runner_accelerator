use super::compile::{AotContext, current_aot_from_context, remove_if_present};
use super::policy::{
    BACKGROUND_AOT_AFTER_EXIT_ENV, BACKGROUND_AOT_LOCK_ENV, BACKGROUND_AOT_SPAWNER_ENV,
};
use super::shared_cache::restore_shared_aot;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

const BACKGROUND_AOT_LOCK_MAX_AGE: Duration = Duration::from_secs(60 * 60);
pub(crate) const AOT_COMPILE_LOCK_NAME: &str = ".aot-background.lock";
/// How long a compiler waits for another process's compile to publish before
/// starting its own. Compiles are ~30s even on large workspaces, so a
/// multi-minute bound covers slow machines while keeping a dead lock holder
/// a bounded stall rather than a hang.
pub(super) const AOT_COMPILE_WAIT_MAX: Duration = Duration::from_secs(300);
const AOT_COMPILE_POLL: Duration = Duration::from_millis(500);

pub(crate) struct BackgroundAotLock {
    pub(super) path: PathBuf,
}

pub(crate) fn take_background_aot_lock() -> Option<BackgroundAotLock> {
    env::var_os(BACKGROUND_AOT_LOCK_ENV).map(|path| BackgroundAotLock {
        path: PathBuf::from(path),
    })
}

/// In a background AOT helper marked with
/// [`BACKGROUND_AOT_AFTER_EXIT_ENV`], wait until the process that spawned
/// the helper has exited, so the compile runs on an idle machine instead
/// of competing with the build that spawned it. Returns true when the
/// compile may proceed: the spawner exited, or the wait does not apply.
/// Returns false when the spawner is still alive at the cap: the helper
/// then exits without compiling rather than compete with a long build.
/// (A reused pid can only cause the false case, never an early compile.)
pub(crate) fn wait_for_background_spawner_exit() -> bool {
    if env::var_os(BACKGROUND_AOT_AFTER_EXIT_ENV).is_none() {
        return true;
    }
    let Some(pid) = env::var(BACKGROUND_AOT_SPAWNER_ENV)
        .ok()
        .and_then(|value| value.parse::<i32>().ok())
    else {
        return true;
    };
    if pid <= 0 || pid == std::process::id() as i32 {
        return true;
    }
    let deadline = Instant::now() + Duration::from_secs(600);
    while process_is_alive(pid) {
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(500));
    }
    true
}

/// Acquires the compile lock for an after-exit helper, which is spawned
/// without holding it (see [`BACKGROUND_AOT_SPAWNER_ENV`]). `Ok(None)`
/// means another compile already holds the lock and this helper's work
/// is redundant.
pub(crate) fn acquire_deferred_background_aot_lock() -> io::Result<Option<BackgroundAotLock>> {
    let Some(path) = env::var_os(BACKGROUND_AOT_LOCK_ENV) else {
        return Ok(None);
    };
    let path = PathBuf::from(path);
    if acquire_background_aot_lock(&path)? {
        Ok(Some(BackgroundAotLock { path }))
    } else {
        Ok(None)
    }
}

#[cfg(unix)]
fn process_is_alive(pid: i32) -> bool {
    // Signal 0 performs error checking without delivering a signal.
    unsafe { libc::kill(pid, 0) == 0 }
}

#[cfg(not(unix))]
fn process_is_alive(_pid: i32) -> bool {
    false
}

impl Drop for BackgroundAotLock {
    fn drop(&mut self) {
        remove_if_present(&self.path);
    }
}

/// Workspace-local single-flight lock shared by every worker AOT compile:
/// `build`'s synchronous compile, `watch`'s spawned background helper, and
/// `prewarm` (foreground or detached) all compete on the same file so only
/// one compile per workspace runs at a time.
pub(super) fn aot_compile_lock_path(context: &AotContext) -> Option<PathBuf> {
    context
        .aot_sdk_root
        .parent()
        .map(|dir| dir.join(AOT_COMPILE_LOCK_NAME))
}

/// Whether this process already owns the workspace compile lock — spawned
/// background helpers receive the path they own through the environment.
pub(super) fn background_aot_lock_owned(lock_path: &Path) -> bool {
    env::var_os(BACKGROUND_AOT_LOCK_ENV).is_some_and(|owned| owned == lock_path)
}

/// Wait for another process's compile to publish a usable artifact. Returns
/// the artifact path on success, `None` when the lock is already self-owned
/// or free, when it is abandoned or outlives the wait bound, or when the
/// winner ended without publishing anything current. A shared-store hit from
/// a parallel compile in another workspace also satisfies the wait.
pub(super) fn wait_for_aot_winner(
    context: &AotContext,
    lock_path: &Path,
    deadline: Instant,
) -> io::Result<Option<PathBuf>> {
    if background_aot_lock_owned(lock_path)
        || !lock_path.is_file()
        || background_aot_lock_is_stale(lock_path)
    {
        return Ok(None);
    }
    eprintln!("Rust worker AOT compile is already running; waiting for the published artifact");
    let wait_start = Instant::now();
    loop {
        if let Some(aot) = current_aot_from_context(context)? {
            if env::var("BUILD_RUNNER_ACCELERATOR_METRICS").as_deref() == Ok("1") {
                eprintln!(
                    "Rust worker AOT wait: elapsed_us={}",
                    wait_start.elapsed().as_micros()
                );
            }
            return Ok(Some(aot));
        }
        if !lock_path.is_file() || background_aot_lock_is_stale(lock_path) {
            // The winner finished (or died). One shared-store probe covers a
            // parallel compile in another workspace that published our key.
            if let Ok(Some(aot)) = restore_shared_aot(context) {
                return Ok(Some(aot));
            }
            return Ok(None);
        }
        if Instant::now() >= deadline {
            // A parallel compile in another workspace can still have a usable
            // slot ready before we fall back to a local compile.
            if let Ok(Some(aot)) = restore_shared_aot(context) {
                return Ok(Some(aot));
            }
            eprintln!(
                "Rust worker AOT wait exceeded {}s; compiling locally",
                AOT_COMPILE_WAIT_MAX.as_secs()
            );
            return Ok(None);
        }
        thread::sleep(AOT_COMPILE_POLL);
    }
}

pub(crate) fn acquire_background_aot_lock(path: &Path) -> io::Result<bool> {
    for attempt in 0..2 {
        match OpenOptions::new().write(true).create_new(true).open(path) {
            Ok(mut file) => {
                if let Err(error) = writeln!(file, "pid={}", std::process::id()) {
                    remove_if_present(path);
                    return Err(error);
                }
                return Ok(true);
            }
            Err(error)
                if error.kind() == io::ErrorKind::AlreadyExists
                    && attempt == 0
                    && background_aot_lock_is_stale(path) =>
            {
                remove_if_present(path);
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => return Ok(false),
            Err(error) => return Err(error),
        }
    }
    Ok(false)
}

pub(super) fn background_aot_lock_is_stale(path: &Path) -> bool {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .and_then(|modified| modified.elapsed().map_err(io::Error::other))
        .is_ok_and(|age| age > BACKGROUND_AOT_LOCK_MAX_AGE)
}
