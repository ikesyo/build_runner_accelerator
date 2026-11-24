use crate::workspace::canonicalize;
use std::env;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::thread;

pub(crate) const BACKGROUND_AOT_LOCK_ENV: &str =
    "BUILD_RUNNER_ACCELERATOR_WORKER_AOT_BACKGROUND_LOCK";
/// Marks a prewarm process spawned as a background AOT helper by a
/// build or watch run, as opposed to a user-invoked `prewarm`: the
/// helper compiles the worker source the spawner selected, exactly
/// as it lies on disk, instead of preparing a manifest from its own
/// (default) options, which could regenerate the worker entrypoint
/// under a different configuration than the spawner's.
pub(crate) const BACKGROUND_AOT_HELPER_ENV: &str =
    "BUILD_RUNNER_ACCELERATOR_WORKER_AOT_BACKGROUND_HELPER";
/// Marks a background AOT helper spawned by a one-shot build: the helper
/// waits for the spawning build process to exit before compiling, so the
/// compile never competes with the build's own workers for CPU.
pub(crate) const BACKGROUND_AOT_AFTER_EXIT_ENV: &str =
    "BUILD_RUNNER_ACCELERATOR_WORKER_AOT_BACKGROUND_AFTER_EXIT";
/// The pid of the build process that spawned an after-exit helper,
/// passed separately because the helper acquires the compile lock only
/// after the wait, so no lock file exists to record the pid in.
pub(crate) const BACKGROUND_AOT_SPAWNER_ENV: &str =
    "BUILD_RUNNER_ACCELERATOR_WORKER_AOT_BACKGROUND_SPAWNER";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AotRequest {
    Disabled,
    Synchronous,
    Force,
    Background,
}

pub(super) fn configured_worker_kernel() -> io::Result<Option<PathBuf>> {
    let Some(value) = env::var_os("BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL") else {
        return Ok(None);
    };
    let path = PathBuf::from(value);
    if !path.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL is not a file: {}",
                path.display()
            ),
        ));
    }
    Ok(Some(canonicalize(path)?))
}

pub(super) fn configured_worker_aot() -> io::Result<Option<PathBuf>> {
    let Some(value) = env::var_os("BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH") else {
        return Ok(None);
    };
    let path = PathBuf::from(value);
    if !path.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH is not a file: {}",
                path.display()
            ),
        ));
    }
    Ok(Some(canonicalize(path)?))
}

/// Command-dependent default worker AOT policy used when the environment
/// does not override it: `watch` favors startup latency (background
/// compile), while one-shot commands use the synchronous policy, which
/// starts on a cached AOT artifact or, on a cold cache, on a kernel worker
/// while the AOT compile proceeds in the background.
static DEFAULT_WORKER_AOT_POLICY: OnceLock<AotRequest> = OnceLock::new();

pub(crate) fn apply_default_worker_aot_policy(command: &str) {
    let _ = DEFAULT_WORKER_AOT_POLICY.set(if command == "watch" {
        AotRequest::Background
    } else {
        AotRequest::Synchronous
    });
}

pub(super) fn aot_request() -> AotRequest {
    let Ok(value) = env::var("BUILD_RUNNER_ACCELERATOR_WORKER_AOT") else {
        return DEFAULT_WORKER_AOT_POLICY
            .get()
            .copied()
            .unwrap_or(AotRequest::Synchronous);
    };
    match value.to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "auto" => AotRequest::Synchronous,
        "force" => AotRequest::Force,
        "background" | "async" => AotRequest::Background,
        _ => AotRequest::Disabled,
    }
}

pub(crate) fn background_aot_requested() -> bool {
    aot_request() == AotRequest::Background
}

pub(crate) fn env_flag_disabled(name: &str) -> bool {
    match env::var(name) {
        Ok(value) => matches!(value.to_lowercase().as_str(), "0" | "false" | "off"),
        Err(_) => false,
    }
}

/// `BUILD_RUNNER_ACCELERATOR_COMPILE_PREWARM=1` opts into overlapping the
/// synchronous worker AOT compile with JIT analysis shards (ADR 0011). Off
/// by default: on fast machines the compile window is too short to fill a
/// meaningful share of the byte store, so the extra processes only add
/// startup cost.
pub(super) fn compile_prewarm_enabled() -> bool {
    env::var("BUILD_RUNNER_ACCELERATOR_COMPILE_PREWARM")
        .map(|value| {
            matches!(
                value.to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

/// Whether `prewarm` should run the whole-workspace analysis shards after the
/// AOT compile (the `prewarm` window). On by default: the sweep fills the
/// shared byte store the first real build would otherwise fill lazily inside
/// worker execution. `BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM=0` opts out
/// for foreground/CI runs where the serial sweep cost has nothing to hide in.
pub(crate) fn analysis_prewarm_enabled() -> bool {
    !env_flag_disabled("BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM")
}

/// `BUILD_RUNNER_ACCELERATOR_MANIFEST_PREWARM=1` opts into running the
/// analysis shards across the whole manifest-generation window (generator
/// kernel compile, early catalog, overlapped worker AOT compile and factory
/// probe); they are killed when manifest generation returns so they never
/// overlap real workers. Off by default: measurement showed the shards
/// contend with the kernel compile, so only the later probe segment is ever
/// worth covering — see `compile_prewarm_enabled` and the ADR.
pub(crate) fn manifest_prewarm_enabled() -> bool {
    env::var("BUILD_RUNNER_ACCELERATOR_MANIFEST_PREWARM")
        .map(|value| {
            matches!(
                value.to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

/// Whether to auto-spawn one summary-only shard while the worker AOT
/// compiles. The only first-touch cost that measured faster under prewarm
/// was the shared SDK summary (`~1-3s` of duplicated `buildSdkSummary` work
/// per cold workspace): it is worth hiding only when it is actually missing
/// and the machine has enough headroom for one extra JIT process, and a
/// shard running with `--dirs none` does no file resolution at all.
/// `BUILD_RUNNER_ACCELERATOR_SDK_SUMMARY_PREWARM=0` opts out.
pub(super) fn sdk_summary_prewarm_enabled(root: &Path) -> bool {
    if env_flag_disabled("BUILD_RUNNER_ACCELERATOR_SDK_SUMMARY_PREWARM") {
        return false;
    }
    // On small machines the shard already contends with the kernel compile
    // and `dart compile exe` that saturate every core.
    if thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(0)
        < 4
    {
        return false;
    }
    !root.join(".dart_tool/build_resolvers/sdk.sum").is_file()
}

pub(super) fn prewarm_jobs() -> usize {
    if let Ok(value) = env::var("BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_JOBS")
        && let Ok(jobs) = value.parse::<usize>()
    {
        return jobs;
    }
    // The AOT compile is mostly single-threaded; spend about half the
    // machine on prewarm.
    thread::available_parallelism()
        .map(|count| count.get() / 2)
        .unwrap_or(0)
}
