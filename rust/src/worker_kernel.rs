use crate::digest::digest_bytes;
use crate::workspace::Workspace;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

const AOT_METADATA_VERSION: u32 = 3;
const AOT_CACHE_KEY_VERSION: &str = "v2";
pub(crate) const BACKGROUND_AOT_LOCK_ENV: &str =
    "BUILD_RUNNER_ACCELERATOR_WORKER_AOT_BACKGROUND_LOCK";
const BACKGROUND_AOT_LOCK_MAX_AGE: Duration = Duration::from_secs(60 * 60);
pub(crate) const AOT_COMPILE_LOCK_NAME: &str = ".aot-background.lock";
/// How long a compiler waits for another process's compile to publish before
/// starting its own. Compiles are ~30s even on large workspaces, so a
/// multi-minute bound covers slow machines while keeping a dead lock holder
/// a bounded stall rather than a hang.
const AOT_COMPILE_WAIT_MAX: Duration = Duration::from_secs(300);
const AOT_COMPILE_POLL: Duration = Duration::from_millis(500);

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum WorkerArtifact {
    Script,
    Kernel(PathBuf),
    Aot(PathBuf),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AotRequest {
    Disabled,
    Synchronous,
    Force,
    Background,
}

#[derive(Debug, Deserialize, Serialize)]
struct AotMetadata {
    format: u32,
    cache_key: String,
    sdk_version: String,
    allowed_experiments: String,
    package_config: String,
    worker: String,
    executable: String,
    dependencies: BTreeMap<String, String>,
}

/// Select the worker launch artifact.
///
/// The launcher requests a synchronous AOT worker for one-shot commands and
/// a background compile for `watch` by default. The request can be disabled,
/// made synchronous, or made strict through the environment. An explicit AOT
/// path takes precedence over every other mode.
///
pub(crate) fn resolve_worker_artifact(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
    auto: bool,
) -> io::Result<WorkerArtifact> {
    if let Some(aot) = configured_worker_aot()? {
        return Ok(WorkerArtifact::Aot(aot));
    }
    if auto && is_dart_source(worker_executable) {
        match aot_request() {
            AotRequest::Force => {
                let aot = prepare_worker_aot(root, dart_binary, worker_executable)?;
                return Ok(WorkerArtifact::Aot(aot));
            }
            AotRequest::Synchronous => {
                // An explicit kernel artifact wins over the automatic
                // synchronous compile. `force` remains strict above.
                if let Some(kernel) = configured_worker_kernel()? {
                    return Ok(WorkerArtifact::Kernel(kernel));
                }
                match prepare_worker_aot(root, dart_binary, worker_executable) {
                    Ok(aot) => return Ok(WorkerArtifact::Aot(aot)),
                    Err(error) => {
                        eprintln!(
                            "Rust worker AOT cache unavailable; using kernel/script ({error})"
                        );
                    }
                }
            }
            AotRequest::Background => {
                // An explicit kernel artifact wins over the automatic
                // background selection and its cached-AOT result.
                if let Some(kernel) = configured_worker_kernel()? {
                    return Ok(WorkerArtifact::Kernel(kernel));
                }
                match prepare_aot_context(root, dart_binary, worker_executable)
                    .and_then(|context| {
                        if let Some(aot) = current_aot_from_context(&context)? {
                            return Ok(Some(aot));
                        }
                        let started = spawn_background_worker_aot(
                            root,
                            dart_binary,
                            worker_executable,
                            &context,
                        )?;
                        if started {
                            eprintln!(
                                "Rust worker AOT cache miss; using Dart script while AOT compiles in background"
                            );
                        } else {
                            eprintln!(
                                "Rust worker AOT compile is already running; using Dart script"
                            );
                        }
                        Ok(None)
                    }) {
                    Ok(Some(aot)) => return Ok(WorkerArtifact::Aot(aot)),
                    Ok(None) => return Ok(WorkerArtifact::Script),
                    Err(error) => {
                        eprintln!(
                            "Rust worker background AOT unavailable; using Dart script ({error})"
                        );
                        return Ok(WorkerArtifact::Script);
                    }
                }
            }
            AotRequest::Disabled => {}
        }
    }
    if let Some(kernel) = configured_worker_kernel()? {
        return Ok(WorkerArtifact::Kernel(kernel));
    }
    if !auto || !is_dart_source(worker_executable) {
        return Ok(WorkerArtifact::Script);
    }

    match prepare_worker_kernel(root, dart_binary, worker_executable) {
        Ok(kernel) => Ok(WorkerArtifact::Kernel(kernel)),
        Err(error) => {
            eprintln!(
                "Rust worker kernel cache unavailable; using Dart script ({error})"
            );
            Ok(WorkerArtifact::Script)
        }
    }
}

pub(crate) fn worker_aot_cache_key(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<String> {
    let worker_path = absolute_worker_path(root, Path::new(worker_executable))?;
    if !is_dart_source(worker_executable) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "AOT prewarm requires a Dart worker source: {}",
                worker_path.display()
            ),
        ));
    }
    let sdk_root = dart_sdk_root(dart_binary)?;
    let workspace = Workspace::load(root.to_path_buf())?;
    aot_cache_key(&workspace, &worker_path, &sdk_root)
}

pub(crate) fn prewarm_worker_aot(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<PathBuf> {
    if !is_dart_source(worker_executable) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "AOT prewarm requires a Dart worker source",
        ));
    }
    prepare_worker_aot(root, dart_binary, worker_executable)
}

/// Starts the synchronous worker AOT compile on a background thread while the
/// manifest generator is still running (the generator emits the worker
/// entrypoint early, before its factory probe). `None` means the AOT policy
/// would not compile synchronously anyway — the build path then stays on the
/// kernel/script or background branches exactly as before.
///
/// The caller MUST join the returned handle before any other
/// `prepare_worker_aot` invocation: temp files are named after the process id
/// and two concurrent compiles in one process would clobber each other.
pub(crate) fn early_worker_aot_compile(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
    readiness: Option<&Path>,
) -> Option<thread::JoinHandle<io::Result<PathBuf>>> {
    if !is_dart_source(worker_executable) {
        return None;
    }
    if !early_worker_aot_enabled() {
        return None;
    }
    let root = root.to_path_buf();
    let dart_binary = dart_binary.to_string();
    let worker_executable = worker_executable.to_string();
    let readiness = readiness.map(Path::to_path_buf);
    let source = fs::read_to_string(&worker_executable).ok();
    Some(thread::spawn(move || {
        // A panic must also settle the invocation-local readiness marker.
        // Otherwise the Dart generator can wait the full readiness timeout
        // before it falls back to the source probe.
        let result =
            catch_worker_aot_panic(|| prepare_worker_aot(&root, &dart_binary, &worker_executable));
        if let Some(readiness) = readiness {
            let message = match (&result, &source) {
                (Ok(path), Some(source))
                    if fs::read_to_string(&worker_executable).ok().as_ref() == Some(source) =>
                {
                    serde_json::json!({"state": "ready", "path": path, "source": source})
                }
                _ => serde_json::json!({"state": "unavailable"}),
            };
            // Invocation-local handoff: the generator also checks exact source.
            let temporary = readiness.with_extension("tmp");
            if fs::write(&temporary, message.to_string()).is_ok() {
                let _ = replace_file(&temporary, &readiness);
            }
        }
        result
    }))
}

fn catch_worker_aot_panic<F>(compile: F) -> io::Result<PathBuf>
where
    F: FnOnce() -> io::Result<PathBuf>,
{
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(compile))
        .unwrap_or_else(|_| Err(io::Error::other("worker AOT compilation panicked")))
}

pub(crate) fn early_worker_aot_enabled() -> bool {
    matches!(aot_request(), AotRequest::Force | AotRequest::Synchronous)
        && configured_worker_aot().ok().flatten().is_none()
        && configured_worker_kernel().ok().flatten().is_none()
}

/// Spawn JIT `AnalysisDriver` processes that resolve the workspace package's
/// sources into the shared byte store, priming both cold-start caches in one
/// `aot-prewarm` step. The caller joins with [`AnalysisPrewarm::wait_for_children`];
/// `None` means the shared byte store is disabled, the accelerator package
/// cannot be located, the workspace has no package config yet, or another
/// prewarm window already owns the shards.
pub(crate) fn start_analysis_prewarm(root: &Path, dart_binary: &str) -> Option<AnalysisPrewarm> {
    spawn_analysis_prewarm(root, dart_binary, "aot-prewarm")
}

/// Same spawner bound to the manifest-generation window: the shards fill the
/// byte store while the generator kernel compiles, the early catalog runs,
/// the overlapped worker AOT builds and the factory probe executes. Dropping
/// the handle at the end of `generate_manifest` cuts them before real workers
/// spawn; `None` follows the same conditions as [`start_analysis_prewarm`].
pub(crate) fn start_manifest_analysis_prewarm(
    root: &Path,
    dart_binary: &str,
) -> Option<AnalysisPrewarm> {
    spawn_analysis_prewarm(root, dart_binary, "manifest")
}

fn is_dart_source(worker_executable: &str) -> bool {
    Path::new(worker_executable)
        .extension()
        .and_then(|extension| extension.to_str())
        == Some("dart")
}

fn configured_worker_kernel() -> io::Result<Option<PathBuf>> {
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
    Ok(Some(fs::canonicalize(path)?))
}

fn configured_worker_aot() -> io::Result<Option<PathBuf>> {
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
    Ok(Some(fs::canonicalize(path)?))
}

/// Command-dependent default worker AOT policy used when the environment
/// does not override it: `watch` favors startup latency (background
/// compile), while one-shot commands favor total wall-clock time
/// (synchronous compile).
static DEFAULT_WORKER_AOT_POLICY: OnceLock<AotRequest> = OnceLock::new();

pub(crate) fn apply_default_worker_aot_policy(command: &str) {
    let _ = DEFAULT_WORKER_AOT_POLICY.set(if command == "watch" {
        AotRequest::Background
    } else {
        AotRequest::Synchronous
    });
}

fn aot_request() -> AotRequest {
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

pub(crate) struct BackgroundAotLock {
    path: PathBuf,
}

pub(crate) fn take_background_aot_lock() -> Option<BackgroundAotLock> {
    env::var_os(BACKGROUND_AOT_LOCK_ENV).map(|path| BackgroundAotLock {
        path: PathBuf::from(path),
    })
}

impl Drop for BackgroundAotLock {
    fn drop(&mut self) {
        remove_if_present(&self.path);
    }
}

/// Machine-wide cache root shared by all workspaces, mirroring the Dart
/// `FrontendBinaryResolver.cacheDirectory` contract:
/// `BUILD_RUNNER_ACCELERATOR_CACHE` wins, then the platform cache directory.
/// A relative override resolves against the workspace root so the Rust
/// frontend and its workers agree even when the launcher runs elsewhere.
pub(crate) fn shared_cache_root(workspace_root: &Path) -> Option<PathBuf> {
    if let Ok(configured) = env::var("BUILD_RUNNER_ACCELERATOR_CACHE") {
        if !configured.is_empty() {
            let path = PathBuf::from(configured);
            return Some(if path.is_absolute() {
                path
            } else {
                workspace_root.join(path)
            });
        }
    }
    if cfg!(target_os = "windows") {
        for variable in ["LOCALAPPDATA", "USERPROFILE"] {
            if let Ok(value) = env::var(variable) {
                if !value.is_empty() {
                    let root = if variable == "USERPROFILE" {
                        PathBuf::from(value).join("AppData").join("Local")
                    } else {
                        PathBuf::from(value)
                    };
                    return Some(root.join("build_runner_accelerator"));
                }
            }
        }
        return None;
    }
    if cfg!(target_os = "macos") {
        let home = env::var_os("HOME")?;
        return Some(
            PathBuf::from(home)
                .join("Library")
                .join("Caches")
                .join("build_runner_accelerator"),
        );
    }
    if let Ok(xdg) = env::var("XDG_CACHE_HOME") {
        if !xdg.is_empty() {
            return Some(PathBuf::from(xdg).join("build_runner_accelerator"));
        }
    }
    let home = env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join(".cache")
            .join("build_runner_accelerator"),
    )
}

/// Directory holding the shared copy of one compiled worker artifact, keyed
/// by the content-derived cache key so different workspaces and checkouts
/// publish and restore the same slot.
fn shared_aot_dir(workspace_root: &Path, cache_key: &str) -> Option<PathBuf> {
    Some(
        shared_cache_root(workspace_root)?
            .join("worker-aot")
            .join(digest_bytes(cache_key.as_bytes())),
    )
}

/// File names making up one cached worker artifact.
fn aot_artifact_file_names(context: &AotContext) -> Option<[OsString; 3]> {
    Some([
        context.aot_path.file_name()?.to_owned(),
        context.depfile_path.file_name()?.to_owned(),
        context.sdk_metadata_path.file_name()?.to_owned(),
    ])
}

/// Restore a previously published artifact into the workspace's `aot-sdk`.
/// Returns the local artifact path when the staged generation passed the same
/// staleness check a local artifact would.
fn restore_shared_aot(context: &AotContext) -> io::Result<Option<PathBuf>> {
    let Some(dir) = shared_aot_dir(&context.workspace.root, &context.cache_key) else {
        return Ok(None);
    };
    let Some([aot_name, depfile_name, metadata_name]) = aot_artifact_file_names(context) else {
        return Ok(None);
    };
    let aot_dir = context
        .aot_path
        .parent()
        .ok_or_else(|| io::Error::other("worker AOT path has no parent directory"))?;
    fs::create_dir_all(aot_dir)?;
    let process_id = std::process::id();

    // Stage the shared trio under temporary names and validate the staged
    // copy. A concurrent `publish_shared_aot` can rotate any of the three
    // files mid-restore; validating the staged generation ensures a mixed
    // set is discarded instead of restored and run.
    let mut staged: Vec<(PathBuf, PathBuf)> = Vec::new();
    for name in [&aot_name, &depfile_name, &metadata_name] {
        let destination = aot_dir.join(name);
        let temp = temporary_sibling(&destination, process_id, "shared");
        if fs::copy(dir.join(name), &temp).is_err() {
            remove_if_present(&temp);
            for (staged_temp, _) in staged.drain(..) {
                remove_if_present(&staged_temp);
            }
            return Ok(None);
        }
        staged.push((temp, destination));
    }
    if !aot_metadata_is_current(
        &staged[0].0,
        &staged[2].0,
        &context.workspace,
        &context.sdk_root,
        &context.worker_path,
        &context.cache_key,
    ) {
        for (staged_temp, _) in staged.drain(..) {
            remove_if_present(&staged_temp);
        }
        return Ok(None);
    }
    for (temp, destination) in staged {
        replace_file(&temp, &destination)?;
    }
    Ok(Some(fs::canonicalize(&context.aot_path)?))
}

/// Publish the freshly compiled artifact so other checkouts and workspaces
/// with the same cache key skip the synchronous compile. The SDK metadata —
/// the file restore validation depends on — is written last, so a slot
/// interrupted mid-publish stays invalid. Best-effort: any failure leaves
/// the shared slot untouched.
fn publish_shared_aot(context: &AotContext) {
    let Some(dir) = shared_aot_dir(&context.workspace.root, &context.cache_key) else {
        return;
    };
    let Some([aot_name, depfile_name, metadata_name]) = aot_artifact_file_names(context) else {
        return;
    };
    let _ = (|| -> io::Result<()> {
        fs::create_dir_all(&dir)?;
        let process_id = std::process::id();
        for (source, name) in [
            (&context.aot_path, aot_name),
            (&context.depfile_path, depfile_name),
            (&context.sdk_metadata_path, metadata_name),
        ] {
            let destination = dir.join(name);
            let temp = temporary_sibling(&destination, process_id, "publish");
            fs::copy(source, &temp)?;
            replace_file(&temp, &destination)?;
        }
        Ok(())
    })();
}

struct AotContext {
    workspace: Workspace,
    sdk_root: PathBuf,
    worker_path: PathBuf,
    cache_key: String,
    aot_sdk_root: PathBuf,
    aot_path: PathBuf,
    depfile_path: PathBuf,
    sdk_metadata_path: PathBuf,
}

fn prepare_aot_context(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<AotContext> {
    let worker_path = absolute_worker_path(root, Path::new(worker_executable))?;
    let sdk_root = dart_sdk_root(dart_binary)?;
    let workspace = Workspace::load(root.to_path_buf())?;
    let cache_key = aot_cache_key(&workspace, &worker_path, &sdk_root)?;
    let aot_sdk_root = worker_path
        .parent()
        .ok_or_else(|| io::Error::other("worker entrypoint has no parent directory"))?
        .join("aot-sdk");
    let aot_bin = aot_sdk_root.join("bin");
    fs::create_dir_all(&aot_bin)?;
    link_sdk_entry(&sdk_root, &aot_sdk_root, "lib")?;
    link_sdk_entry(&sdk_root, &aot_sdk_root, "version")?;
    // Flutter keeps dart:ui outside the Dart SDK root at
    // `<cache>/pkg/sky_engine`. Mirror it next to `aot-sdk` so lookups
    // relative to `Platform.resolvedExecutable` (e.g. build_runner's
    // `isFlutter` detection when generating the SDK summary) still work
    // inside the self-contained worker executable.
    if let (Some(sdk_parent), Some(aot_parent)) =
        (sdk_root.parent(), aot_sdk_root.parent())
    {
        if sdk_parent.join("pkg").is_dir() {
            link_sdk_entry(sdk_parent, aot_parent, "pkg")?;
        }
    }
    let aot_path = aot_bin.join(aot_file_name(&worker_path));
    let depfile_path = PathBuf::from(format!("{}.d", aot_path.display()));
    let sdk_metadata_path = PathBuf::from(format!("{}.sdk", aot_path.display()));
    Ok(AotContext {
        workspace,
        sdk_root,
        worker_path,
        cache_key,
        aot_sdk_root,
        aot_path,
        depfile_path,
        sdk_metadata_path,
    })
}

fn current_aot_from_context(context: &AotContext) -> io::Result<Option<PathBuf>> {
    if aot_metadata_is_current(
        &context.aot_path,
        &context.sdk_metadata_path,
        &context.workspace,
        &context.sdk_root,
        &context.worker_path,
        &context.cache_key,
    ) {
        return Ok(Some(fs::canonicalize(&context.aot_path)?));
    }
    Ok(None)
}

/// Checks whether a pinned compiled worker still matches its current inputs.
/// Script workers are deliberately treated as current so a watch session does
/// not switch to an AOT worker that finished compiling after the session began.
pub(crate) fn pinned_worker_artifact_is_current(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
    artifact: &WorkerArtifact,
) -> io::Result<bool> {
    match artifact {
        WorkerArtifact::Script => Ok(true),
        WorkerArtifact::Aot(path) => {
            if let Some(configured) = configured_worker_aot()? {
                return Ok(configured.as_path() == path.as_path());
            }
            let context = prepare_aot_context(root, dart_binary, worker_executable)?;
            Ok(current_aot_from_context(&context)?
                .as_ref()
                .is_some_and(|current| current.as_path() == path.as_path()))
        }
        WorkerArtifact::Kernel(path) => {
            if let Some(configured) = configured_worker_kernel()? {
                return Ok(configured.as_path() == path.as_path());
            }
            let worker_path = absolute_worker_path(root, Path::new(worker_executable))?;
            let kernel_path = worker_path.with_extension("dill");
            let depfile_path = PathBuf::from(format!("{}.d", kernel_path.display()));
            if !worker_artifact_is_current(&kernel_path, &depfile_path, &worker_path) {
                return Ok(false);
            }
            Ok(fs::canonicalize(kernel_path)?.as_path() == path.as_path())
        }
    }
}

pub(crate) fn background_worker_aot_if_ready(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<Option<PathBuf>> {
    if !background_aot_requested() || !is_dart_source(worker_executable) {
        return Ok(None);
    }
    // Explicitly configured worker artifacts are never swapped for a cached
    // background AOT compile result.
    if configured_worker_aot()?.is_some() || configured_worker_kernel()?.is_some() {
        return Ok(None);
    }
    let context = prepare_aot_context(root, dart_binary, worker_executable)?;
    current_aot_from_context(&context)
}

fn prepare_worker_aot(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<PathBuf> {
    let context = prepare_aot_context(root, dart_binary, worker_executable)?;
    if let Some(aot) = current_aot_from_context(&context)? {
        return Ok(aot);
    }
    // A fresh checkout has no workspace-local artifact, but a previous build
    // (here or in another checkout) may have published this exact key to the
    // machine-wide cache.
    if let Ok(Some(aot)) = restore_shared_aot(&context) {
        return Ok(aot);
    }

    // Single-flight: one process compiles per workspace at a time. A loser
    // waits for the winner's published artifact — compiles produce identical
    // content under the same cache key, so waiting is strictly better than
    // duplicating them. The env-var path marks a lock this process already
    // owns (a spawned background helper); everything else is external.
    let lock_path = aot_compile_lock_path(&context);
    if let Some(lock_path) = &lock_path {
        if let Some(aot) = wait_for_aot_winner(&context, lock_path)? {
            return Ok(aot);
        }
    }
    // The guard keeps the lock file until the fresh artifact is published.
    // A lost race means another compile started between the wait above and
    // here: wait for it once, then compile anyway — atomic temp-file publish
    // keeps a duplicate compile safe, just wasteful.
    let _compile_lock = match &lock_path {
        Some(lock_path) if !background_aot_lock_owned(lock_path) => {
            if acquire_background_aot_lock(lock_path)? {
                Some(BackgroundAotLock {
                    path: lock_path.clone(),
                })
            } else {
                match wait_for_aot_winner(&context, lock_path)? {
                    Some(aot) => return Ok(aot),
                    None => None,
                }
            }
        }
        _ => None,
    };

    // Opt-in overlap: the compile is mostly single-threaded, so JIT
    // analysis shards can start filling the shared byte store meanwhile.
    // The shards are killed as soon as the compile ends (see `AnalysisPrewarm`'s
    // `Drop`) so they never compete with the workers that follow. When a
    // wider prewarm window (e.g. manifest generation) already owns the
    // shards this spawn is skipped instead of doubling them. Without the
    // opt-in, a single summary-only shard still runs when the workspace has
    // no SDK summary yet — hiding the one first-touch cost that measured
    // faster (see `sdk_summary_prewarm_enabled`).
    let analysis_prewarm = if compile_prewarm_enabled() {
        spawn_analysis_prewarm(&context.workspace.root, dart_binary, "compile")
    } else if sdk_summary_prewarm_enabled(&context.workspace.root) {
        spawn_analysis_prewarm_options(
            &context.workspace.root,
            dart_binary,
            "sdk-summary",
            Some(1),
            Some("none"),
        )
    } else {
        None
    };
    let process_id = std::process::id();
    let temp_aot = temporary_sibling(&context.aot_path, process_id, "aot");
    let temp_depfile = temporary_sibling(&context.depfile_path, process_id, "d");
    let temp_sdk_metadata = temporary_sibling(&context.sdk_metadata_path, process_id, "sdk");
    // The compiler only writes its output at the end of a long single-threaded
    // compile, so re-assert the output directory here: anything that removed
    // `aot-sdk` after `prepare_aot_context` would otherwise surface as a
    // PathNotFound when the compile finally emits the binary.
    if let Some(parent) = temp_aot.parent() {
        fs::create_dir_all(parent)?;
    }
    let package_config = context
        .workspace
        .root
        .join(".dart_tool/package_config.json");
    let compile_start = Instant::now();
    let status = Command::new(dart_binary)
        .args(["--suppress-analytics", "compile", "exe"])
        .arg(format!("--packages={}", package_config.display()))
        .arg(format!("--depfile={}", temp_depfile.display()))
        .arg(&context.worker_path)
        .arg("-o")
        .arg(&temp_aot)
        .current_dir(&context.workspace.root)
        .status()
        .map_err(|error| aot_compile_error(&context.worker_path, error))?;
    drop(analysis_prewarm);
    if env::var("BUILD_RUNNER_ACCELERATOR_METRICS").as_deref() == Ok("1") {
        eprintln!(
            "Rust worker AOT compile: elapsed_us={}",
            compile_start.elapsed().as_micros()
        );
    }
    if !status.success() {
        remove_if_present(&temp_aot);
        remove_if_present(&temp_depfile);
        remove_if_present(&temp_sdk_metadata);
        return Err(aot_compile_status_error(&context.worker_path, status));
    }

    let metadata = build_aot_metadata(
        &context.workspace,
        &context.sdk_root,
        &context.worker_path,
        &temp_depfile,
        &temp_aot,
        &context.cache_key,
    )?;
    fs::write(
        &temp_sdk_metadata,
        serde_json::to_vec_pretty(&metadata).map_err(io::Error::other)?,
    )?;

    // Publish the dependency list before the executable. If the second rename
    // is interrupted, the old executable is conservatively treated as stale.
    replace_file(&temp_depfile, &context.depfile_path)?;
    replace_file(&temp_sdk_metadata, &context.sdk_metadata_path)?;
    replace_file(&temp_aot, &context.aot_path)?;
    publish_shared_aot(&context);
    fs::canonicalize(context.aot_path)
}

fn spawn_background_worker_aot(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
    context: &AotContext,
) -> io::Result<bool> {
    let lock_path = aot_compile_lock_path(context)
        .ok_or_else(|| io::Error::other("AOT SDK directory has no parent"))?;
    if !acquire_background_aot_lock(&lock_path)? {
        return Ok(false);
    }

    let current_exe = match env::current_exe() {
        Ok(path) => path,
        Err(error) => {
            remove_if_present(&lock_path);
            return Err(error);
        }
    };
    let result = Command::new(current_exe)
        .args(["prewarm", "--root"])
        .arg(root)
        .args(["--dart"])
        .arg(dart_binary)
        .args(["--worker"])
        .arg(worker_executable)
        .args(["--mode", "rust"])
        .current_dir(root)
        .env(BACKGROUND_AOT_LOCK_ENV, &lock_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    match result {
        Ok(mut child) => {
            // Reap the helper while the foreground process remains alive
            // (notably during watch). If the foreground process exits first,
            // the child is re-parented and can finish independently.
            thread::spawn(move || {
                let _ = child.wait();
            });
            Ok(true)
        }
        Err(error) => {
            remove_if_present(&lock_path);
            Err(error)
        }
    }
}

/// Workspace-local single-flight lock shared by every worker AOT compile:
/// `build`'s synchronous compile, `watch`'s spawned background helper, and
/// `prewarm` (foreground or detached) all compete on the same file so only
/// one compile per workspace runs at a time.
fn aot_compile_lock_path(context: &AotContext) -> Option<PathBuf> {
    context
        .aot_sdk_root
        .parent()
        .map(|dir| dir.join(AOT_COMPILE_LOCK_NAME))
}

/// Whether this process already owns the workspace compile lock — spawned
/// background helpers receive the path they own through the environment.
fn background_aot_lock_owned(lock_path: &Path) -> bool {
    env::var_os(BACKGROUND_AOT_LOCK_ENV).is_some_and(|owned| PathBuf::from(owned) == lock_path)
}

/// Wait for another process's compile to publish a usable artifact. Returns
/// the artifact path on success, `None` when the lock is already self-owned
/// or free, when it is abandoned or outlives the wait bound, or when the
/// winner ended without publishing anything current. A shared-store hit from
/// a parallel compile in another workspace also satisfies the wait.
fn wait_for_aot_winner(context: &AotContext, lock_path: &Path) -> io::Result<Option<PathBuf>> {
    if background_aot_lock_owned(lock_path)
        || !lock_path.is_file()
        || background_aot_lock_is_stale(lock_path)
    {
        return Ok(None);
    }
    eprintln!("Rust worker AOT compile is already running; waiting for the published artifact");
    let wait_start = Instant::now();
    let deadline = wait_start + AOT_COMPILE_WAIT_MAX;
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

fn background_aot_lock_is_stale(path: &Path) -> bool {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .and_then(|modified| modified.elapsed().map_err(io::Error::other))
        .is_ok_and(|age| age > BACKGROUND_AOT_LOCK_MAX_AGE)
}

fn aot_cache_key(workspace: &Workspace, worker_path: &Path, sdk_root: &Path) -> io::Result<String> {
    let (sdk_version, allowed_experiments) = aot_sdk_identity(sdk_root)?;
    let manifest = workspace.builder_manifest_fingerprint()?;
    let lock = digest_optional_file(&workspace.root.join("pubspec.lock"))?;
    let worker = digest_file(worker_path)?;
    let package_config = workspace.package_config_identity();
    Ok(format!(
        "build-runner-accelerator-aot-{AOT_CACHE_KEY_VERSION}-{}-{}-sdk{}-allowed{}-manifest{}-lock{}-worker{}-packages{}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        sdk_version,
        allowed_experiments,
        manifest,
        lock,
        worker,
        package_config,
    ))
}

pub(crate) fn aot_sdk_identity(sdk_root: &Path) -> io::Result<(String, String)> {
    let sdk_root = fs::canonicalize(sdk_root)?;
    let version = fs::read(sdk_root.join("version"))?;
    let allowed_experiments = fs::read(
        sdk_root
            .join("lib")
            .join("_internal")
            .join("allowed_experiments.json"),
    )?;
    Ok((digest_bytes(&version), digest_bytes(&allowed_experiments)))
}

fn build_aot_metadata(
    workspace: &Workspace,
    sdk_root: &Path,
    worker_path: &Path,
    depfile: &Path,
    executable_path: &Path,
    cache_key: &str,
) -> io::Result<AotMetadata> {
    let dependencies = parse_depfile_dependencies(&fs::read_to_string(depfile)?)
        .ok_or_else(|| io::Error::other("AOT compiler depfile has no dependencies"))?;
    let package_config_path =
        fs::canonicalize(workspace.root.join(".dart_tool/package_config.json"))?;
    let canonical_sdk_root = fs::canonicalize(sdk_root)?;
    let mut dependency_digests = BTreeMap::new();
    for dependency in dependencies {
        let dependency = fs::canonicalize(dependency)?;
        if dependency == package_config_path || dependency.strip_prefix(&canonical_sdk_root).is_ok()
        {
            continue;
        }
        let key = workspace
            .logical_dependency_key(&dependency)
            .ok_or_else(|| {
                io::Error::other(format!(
                    "AOT dependency is outside the workspace/package graph: {}",
                    dependency.display()
                ))
            })?;
        dependency_digests.insert(key, digest_file(&dependency)?);
    }
    let (sdk_version, allowed_experiments) = aot_sdk_identity(sdk_root)?;
    Ok(AotMetadata {
        format: AOT_METADATA_VERSION,
        cache_key: cache_key.to_owned(),
        sdk_version,
        allowed_experiments,
        package_config: workspace.package_config_identity().to_owned(),
        worker: digest_file(worker_path)?,
        executable: digest_file(executable_path)?,
        dependencies: dependency_digests,
    })
}

fn aot_metadata_is_current(
    artifact: &Path,
    metadata_path: &Path,
    workspace: &Workspace,
    sdk_root: &Path,
    worker_path: &Path,
    cache_key: &str,
) -> bool {
    if !artifact.is_file() {
        return false;
    }
    let Ok(contents) = fs::read_to_string(metadata_path) else {
        return false;
    };
    let Ok(metadata) = serde_json::from_str::<AotMetadata>(&contents) else {
        return false;
    };
    if metadata.format != AOT_METADATA_VERSION
        || metadata.cache_key != cache_key
        || metadata.package_config != workspace.package_config_identity()
    {
        return false;
    }
    let Ok((sdk_version, allowed_experiments)) = aot_sdk_identity(sdk_root) else {
        return false;
    };
    if metadata.sdk_version != sdk_version || metadata.allowed_experiments != allowed_experiments {
        return false;
    }
    let Ok(worker_digest) = digest_file(worker_path) else {
        return false;
    };
    if metadata.worker != worker_digest {
        return false;
    }
    // The digest ties the metadata to the exact executable that produced it,
    // so a staged restore cannot pair a truncated file with an older
    // machine-wide generation.
    let Ok(executable_digest) = digest_file(artifact) else {
        return false;
    };
    if metadata.executable != executable_digest {
        return false;
    }
    metadata.dependencies.iter().all(|(key, expected)| {
        workspace
            .resolve_logical_dependency(key)
            .and_then(|path| digest_file(&path).ok())
            .is_some_and(|actual| actual == *expected)
    })
}

fn digest_file(path: &Path) -> io::Result<String> {
    Ok(digest_bytes(&fs::read(path)?))
}

fn digest_optional_file(path: &Path) -> io::Result<String> {
    match fs::read(path) {
        Ok(contents) => Ok(digest_bytes(&normalize_text_bytes(&contents))),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok("missing".to_owned()),
        Err(error) => Err(error),
    }
}

fn normalize_text_bytes(contents: &[u8]) -> Vec<u8> {
    let mut normalized = Vec::with_capacity(contents.len());
    let mut index = 0;
    while index < contents.len() {
        if contents[index] == b'\r' {
            normalized.push(b'\n');
            if contents.get(index + 1) == Some(&b'\n') {
                index += 1;
            }
        } else {
            normalized.push(contents[index]);
        }
        index += 1;
    }
    normalized
}

fn dart_sdk_root(dart_binary: &str) -> io::Result<PathBuf> {
    if let Some(value) = env::var_os("DART_SDK") {
        let path = PathBuf::from(value);
        if path.join("lib").is_dir() {
            return fs::canonicalize(path);
        }
    }

    dart_sdk_root_for_binary(dart_binary)
}

// Generator kernels must match the VM that will execute them, even when an
// independent DART_SDK override is used for worker AOT preparation.
pub(crate) fn dart_sdk_root_for_binary(dart_binary: &str) -> io::Result<PathBuf> {
    let dart_path = if Path::new(dart_binary).is_absolute()
        || Path::new(dart_binary).parent().is_some_and(|parent| !parent.as_os_str().is_empty())
    {
        PathBuf::from(dart_binary)
    } else {
        find_on_path(dart_binary)?
    };
    let dart_path = fs::canonicalize(dart_path)?;
    let bin_dir = dart_path
        .parent()
        .ok_or_else(|| io::Error::other("Dart executable has no parent directory"))?;
    let sdk_root = bin_dir
        .parent()
        .ok_or_else(|| io::Error::other("Dart executable is not inside an SDK"))?;
    if !sdk_root.join("lib").is_dir() {
        return Err(io::Error::other(format!(
            "Dart SDK lib directory not found: {}",
            sdk_root.join("lib").display()
        )));
    }
    Ok(sdk_root.to_owned())
}

fn find_on_path(program: &str) -> io::Result<PathBuf> {
    let path = env::var_os("PATH")
        .ok_or_else(|| io::Error::other("PATH is not set; cannot locate Dart"))?;
    for directory in env::split_paths(&path) {
        let candidate = directory.join(program);
        if candidate.is_file() {
            return Ok(candidate);
        }
        #[cfg(windows)]
        if Path::new(program).extension().is_none() {
            let candidate = directory.join(format!("{program}.exe"));
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("Dart executable not found on PATH: {program}"),
    ))
}

fn aot_file_name(worker: &Path) -> OsString {
    #[cfg(windows)]
    {
        let mut name = worker
            .file_stem()
            .map(OsString::from)
            .unwrap_or_else(|| OsString::from("dynamic_worker"));
        name.push(".exe");
        name
    }
    #[cfg(not(windows))]
    {
        worker
            .file_stem()
            .map(OsString::from)
            .unwrap_or_else(|| OsString::from("dynamic_worker"))
    }
}

fn link_sdk_entry(sdk_root: &Path, aot_sdk_root: &Path, name: &str) -> io::Result<()> {
    let source = sdk_root.join(name);
    if !source.exists() {
        return Err(io::Error::other(format!(
            "Dart SDK entry not found: {}",
            source.display()
        )));
    }
    let destination = aot_sdk_root.join(name);
    if let Ok(existing) = fs::read_link(&destination) {
        let existing = if existing.is_absolute() {
            existing
        } else {
            destination
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .join(existing)
        };
        if fs::canonicalize(existing).ok() == fs::canonicalize(&source).ok() {
            return Ok(());
        }
        // A concurrent compile can remove or recreate the same link.
        if let Err(error) = fs::remove_file(&destination) {
            if error.kind() != io::ErrorKind::NotFound {
                return Err(error);
            }
        }
    } else if destination.exists() {
        return Err(io::Error::other(format!(
            "AOT SDK path is not a symlink: {}",
            destination.display()
        )));
    }

    let link_result = (|| -> io::Result<()> {
        #[cfg(unix)]
        std::os::unix::fs::symlink(&source, &destination)?;
        #[cfg(windows)]
        if source.is_dir() {
            std::os::windows::fs::symlink_dir(&source, &destination)?;
        } else {
            std::os::windows::fs::symlink_file(&source, &destination)?;
        }
        #[cfg(not(any(unix, windows)))]
        return Err(io::Error::other(
            "AOT worker SDK layout requires symbolic links on this platform",
        ));
        Ok(())
    })();
    if let Err(error) = link_result {
        // A concurrent compile may have created the same link meanwhile;
        // accept it when it resolves to the same SDK entry.
        if error.kind() == io::ErrorKind::AlreadyExists {
            if let Ok(existing) = fs::read_link(&destination) {
                let existing = if existing.is_absolute() {
                    existing
                } else {
                    destination
                        .parent()
                        .unwrap_or_else(|| Path::new("."))
                        .join(existing)
                };
                if fs::canonicalize(existing).ok() == fs::canonicalize(&source).ok() {
                    return Ok(());
                }
            }
        }
        return Err(error);
    }
    Ok(())
}

fn prepare_worker_kernel(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<PathBuf> {
    let worker_path = absolute_worker_path(root, Path::new(worker_executable))?;
    let kernel_path = worker_path.with_extension("dill");
    let depfile_path = PathBuf::from(format!("{}.d", kernel_path.display()));
    if worker_artifact_is_current(&kernel_path, &depfile_path, &worker_path) {
        return fs::canonicalize(kernel_path);
    }

    let process_id = std::process::id();
    let temp_kernel = temporary_sibling(&kernel_path, process_id, "dill");
    let temp_depfile = temporary_sibling(&depfile_path, process_id, "d");
    let package_config = root.join(".dart_tool/package_config.json");
    let status = Command::new(dart_binary)
        .args(["--suppress-analytics", "compile", "kernel"])
        .arg("--no-embed-sources")
        .arg(format!("--packages={}", package_config.display()))
        .arg(format!("--depfile={}", temp_depfile.display()))
        .arg(&worker_path)
        .arg("-o")
        .arg(&temp_kernel)
        .current_dir(root)
        .status()
        .map_err(|error| kernel_compile_error(&worker_path, error))?;
    if !status.success() {
        remove_if_present(&temp_kernel);
        remove_if_present(&temp_depfile);
        return Err(kernel_compile_status_error(&worker_path, status));
    }

    // Publish the dependency list before the kernel. If the second rename is
    // interrupted, the old kernel is conservatively treated as stale.
    replace_file(&temp_depfile, &depfile_path)?;
    replace_file(&temp_kernel, &kernel_path)?;
    fs::canonicalize(kernel_path)
}

fn absolute_worker_path(root: &Path, worker_path: &Path) -> io::Result<PathBuf> {
    let path = if worker_path.is_absolute() {
        worker_path.to_path_buf()
    } else {
        root.join(worker_path)
    };
    fs::canonicalize(path)
}

fn worker_artifact_is_current(artifact: &Path, depfile: &Path, worker: &Path) -> bool {
    let Ok(artifact_modified) = fs::metadata(artifact).and_then(|metadata| metadata.modified()) else {
        return false;
    };
    let Ok(contents) = fs::read_to_string(depfile) else {
        return false;
    };
    let Some(dependencies) = parse_depfile_dependencies(&contents) else {
        return false;
    };
    dependencies.iter().any(|path| path == worker)
        && dependencies.iter().all(|path| {
            fs::metadata(path)
                .and_then(|metadata| metadata.modified())
                .is_ok_and(|modified| modified <= artifact_modified)
        })
}

pub(crate) fn parse_depfile_dependencies(contents: &str) -> Option<Vec<PathBuf>> {
    let mut logical = String::with_capacity(contents.len());
    let mut characters = contents.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\\' {
            match characters.peek() {
                Some('\n') => {
                    characters.next();
                    logical.push(' ');
                    continue;
                }
                Some('\r') => {
                    characters.next();
                    if characters.peek() == Some(&'\n') {
                        characters.next();
                    }
                    logical.push(' ');
                    continue;
                }
                _ => {}
            }
        }
        logical.push(character);
    }

    let separator = logical
        .find(": ")
        .or_else(|| logical.find(':'))?;
    let dependencies = make_words(&logical[separator + 1..]);
    (!dependencies.is_empty()).then_some(dependencies.into_iter().map(PathBuf::from).collect())
}

fn make_words(value: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut escaped = false;
    for character in value.chars() {
        if escaped {
            word.push(character);
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else if character.is_whitespace() {
            if !word.is_empty() {
                words.push(std::mem::take(&mut word));
            }
        } else {
            word.push(character);
        }
    }
    if escaped {
        word.push('\\');
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
}

fn temporary_sibling(path: &Path, process_id: u32, extension: &str) -> PathBuf {
    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("worker-cache");
    path.with_file_name(format!(".{filename}.{process_id}.tmp.{extension}"))
}

fn replace_file(source: &Path, destination: &Path) -> io::Result<()> {
    #[cfg(windows)]
    if destination.exists() {
        fs::remove_file(destination)?;
    }
    fs::rename(source, destination)
}

fn remove_if_present(path: &Path) {
    let _ = fs::remove_file(path);
}

fn kernel_compile_error(worker: &Path, error: io::Error) -> io::Error {
    io::Error::new(
        error.kind(),
        format!("failed to compile worker kernel for {}: {error}", worker.display()),
    )
}

fn kernel_compile_status_error(worker: &Path, status: std::process::ExitStatus) -> io::Error {
    io::Error::other(format!(
        "worker kernel compilation exited with {status}: {}",
        worker.display()
    ))
}

fn aot_compile_error(worker: &Path, error: io::Error) -> io::Error {
    io::Error::new(
        error.kind(),
        format!("failed to compile worker AOT executable for {}: {error}", worker.display()),
    )
}

fn aot_compile_status_error(worker: &Path, status: std::process::ExitStatus) -> io::Error {
    io::Error::other(format!(
        "worker AOT compilation exited with {status}: {}",
        worker.display()
    ))
}

/// JIT analyzer prewarm spawned by `aot-prewarm` to fill the shared byte
/// store.
///
/// `bin/prewarm_analysis.dart` resolves workspace sources through a plain Dart
/// `AnalysisDriver` writing the same content-addressed on-disk byte store the
/// compiled workers read (see `shared_analysis_cache_enabled` /
/// `lib/src/worker_resolvers.dart`), so worker first-touch analysis becomes a
/// disk hit instead of recomputing the same graph per worker.
pub(crate) struct AnalysisPrewarm {
    children: Vec<Child>,
}

impl AnalysisPrewarm {
    /// Wait for every prewarm process to finish on its own.
    pub(crate) fn wait_for_children(mut self) {
        for mut child in std::mem::take(&mut self.children) {
            let _ = child.wait();
        }
    }
}

impl Drop for AnalysisPrewarm {
    fn drop(&mut self) {
        for child in &mut self.children {
            let _ = child.kill();
        }
        for child in &mut self.children {
            let _ = child.wait();
        }
        ANALYSIS_PREWARM_ACTIVE.store(false, Ordering::Release);
    }
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
fn compile_prewarm_enabled() -> bool {
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
/// AOT compile (the `aot-prewarm` window). On by default: the sweep fills the
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
fn sdk_summary_prewarm_enabled(root: &Path) -> bool {
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
    !root
        .join(".dart_tool/build_resolvers/sdk.sum")
        .is_file()
}

fn prewarm_jobs() -> usize {
    if let Ok(value) = env::var("BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_JOBS") {
        if let Ok(jobs) = value.parse::<usize>() {
            return jobs;
        }
    }
    // The AOT compile is mostly single-threaded; spend about half the
    // machine on prewarm.
    thread::available_parallelism()
        .map(|count| count.get() / 2)
        .unwrap_or(0)
}

fn prewarm_script_path(root: &Path) -> Option<PathBuf> {
    let config_path = root.join(".dart_tool/package_config.json");
    let text = fs::read_to_string(&config_path).ok()?;
    let config: serde_json::Value = serde_json::from_str(&text).ok()?;
    let package = config
        .get("packages")?
        .as_array()?
        .iter()
        .find(|package| {
            package.get("name").and_then(|name| name.as_str())
                == Some("build_runner_accelerator")
        })?;
    let root_uri = package.get("rootUri")?.as_str()?;
    let package_root = resolve_package_root_uri(&config_path, root_uri)?;
    let script = package_root.join("bin/prewarm_analysis.dart");
    script.is_file().then_some(script)
}

/// Convert a package-config `rootUri` to a filesystem path. `file://`
/// URIs are percent-decoded and lose the leading `/` of a Windows
/// drive-letter spelling (`file:///C:/...`); relative references resolve
/// against the package config's directory after decoding.
fn resolve_package_root_uri(config_path: &Path, root_uri: &str) -> Option<PathBuf> {
    if let Some(path) = root_uri.strip_prefix("file://") {
        let decoded = decode_uri_escapes(path);
        let decoded = decoded
            .strip_prefix('/')
            .filter(|rest| {
                let bytes = rest.as_bytes();
                bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
            })
            .unwrap_or(&decoded);
        Some(PathBuf::from(decoded))
    } else {
        Some(config_path.parent()?.join(decode_uri_escapes(root_uri)))
    }
}

/// Expand `%XX` escapes in a URI path component. Invalid escapes and
/// non-UTF-8 results degrade gracefully: the caller only probes existence.
fn decode_uri_escapes(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) =
                (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
            {
                out.push(high * 16 + low);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// Only one prewarm window runs per frontend process. The manifest-window
/// spawn subsumes the narrower compile-window spawn inside
/// `prepare_worker_aot`, which would otherwise double the shard count when
/// both are enabled.
static ANALYSIS_PREWARM_ACTIVE: AtomicBool = AtomicBool::new(false);

fn spawn_analysis_prewarm(root: &Path, dart_binary: &str, window: &str) -> Option<AnalysisPrewarm> {
    spawn_analysis_prewarm_options(root, dart_binary, window, None, None)
}

fn spawn_analysis_prewarm_options(
    root: &Path,
    dart_binary: &str,
    window: &str,
    jobs: Option<usize>,
    dirs: Option<&str>,
) -> Option<AnalysisPrewarm> {
    if env_flag_disabled("BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM")
        || !crate::worker::shared_analysis_cache_enabled()
    {
        return None;
    }
    if ANALYSIS_PREWARM_ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return None;
    }
    let Some(script) = prewarm_script_path(root) else {
        ANALYSIS_PREWARM_ACTIVE.store(false, Ordering::Release);
        return None;
    };
    let shards = jobs.unwrap_or_else(prewarm_jobs);
    if shards == 0 {
        ANALYSIS_PREWARM_ACTIVE.store(false, Ordering::Release);
        return None;
    }
    let package_config = root.join(".dart_tool/package_config.json");
    let dirs = dirs.map(str::to_owned).or_else(|| {
        env::var("BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_DIRS")
            .ok()
            .filter(|value| !value.trim().is_empty())
    });
    let children: Vec<Child> = (0..shards)
        .filter_map(|shard| {
            let mut command = Command::new(dart_binary);
            command
                .arg(format!("--packages={}", package_config.display()))
                .arg(&script)
                .arg("--shard")
                .arg(shard.to_string())
                .arg("--shards")
                .arg(shards.to_string());
            if let Some(dirs) = &dirs {
                command.arg("--dirs").arg(dirs);
            }
            command
                .current_dir(root)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .map_err(|error| {
                    eprintln!("analysis prewarm shard {shard} failed to spawn: {error}");
                    error
                })
                .ok()
        })
        .collect();
    if children.is_empty() {
        ANALYSIS_PREWARM_ACTIVE.store(false, Ordering::Release);
        None
    } else {
        eprintln!(
            "analysis prewarm[{window}]: {} shard(s) resolving workspace sources",
            children.len()
        );
        Some(AnalysisPrewarm { children })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ANALYSIS_PREWARM_ACTIVE, WorkerArtifact, acquire_background_aot_lock,
        analysis_prewarm_enabled, background_aot_lock_is_stale, catch_worker_aot_panic,
        parse_depfile_dependencies, pinned_worker_artifact_is_current, spawn_analysis_prewarm,
    };
    use std::fs::{self, OpenOptions};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::Ordering;
    use std::sync::{Arc, Barrier};
    use std::thread;

    #[test]
    fn early_worker_aot_panics_are_caught() {
        let result = catch_worker_aot_panic(|| -> std::io::Result<PathBuf> {
            panic!("injected AOT panic");
        });
        assert!(result.is_err());
    }

    #[test]
    fn depfile_parser_handles_continuations_and_escaped_spaces() {
        let depfile = concat!(
            "/tmp/worker.dill: /tmp/package_config.json /tmp/path\\ with\\ spaces.dart \\\n",
            " /tmp/other.dart\n",
        );
        let dependencies = parse_depfile_dependencies(depfile).expect("dependencies");
        assert_eq!(
            dependencies,
            vec![
                PathBuf::from("/tmp/package_config.json"),
                PathBuf::from("/tmp/path with spaces.dart"),
                PathBuf::from("/tmp/other.dart"),
            ]
        );
    }

    #[test]
    fn worker_artifact_distinguishes_aot_from_kernel() {
        assert_ne!(
            WorkerArtifact::Aot(PathBuf::from("worker.aot")),
            WorkerArtifact::Kernel(PathBuf::from("worker.dill"))
        );
    }

    #[test]
    fn pinned_script_worker_stays_current_when_aot_may_finish() {
        assert!(pinned_worker_artifact_is_current(
            Path::new("unused"),
            "unused",
            "unused.dart",
            &WorkerArtifact::Script,
        )
        .unwrap());
    }

    #[test]
    fn background_lock_is_single_flight() {
        let path = std::env::temp_dir().join(format!("build-runner-accelerator-lock-{}", std::process::id()));
        let _ = fs::remove_file(&path);
        let gate = Arc::new(Barrier::new(8));
        let handles = (0..8).map(|_| {
            let gate = Arc::clone(&gate);
            let path = path.clone();
            thread::spawn(move || {
                gate.wait();
                acquire_background_aot_lock(&path).unwrap()
            })
        }).collect::<Vec<_>>();
        let owners = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .filter(|owned| *owned)
            .count();
        assert_eq!(owners, 1);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn fresh_background_lock_is_not_stale() {
        let path = std::env::temp_dir().join(format!("build-runner-accelerator-fresh-lock-{}", std::process::id()));
        let _ = fs::remove_file(&path);
        OpenOptions::new().create_new(true).write(true).open(&path).unwrap();
        assert!(!background_aot_lock_is_stale(&path));
        let _ = fs::remove_file(path);
    }

    static PREWARM_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn analysis_prewarm_spawn_is_single_flight() {
        let _guard = PREWARM_TEST_LOCK.lock().unwrap();
        ANALYSIS_PREWARM_ACTIVE.store(true, Ordering::SeqCst);
        assert!(spawn_analysis_prewarm(Path::new("/nonexistent"), "dart", "test").is_none());
        ANALYSIS_PREWARM_ACTIVE.store(false, Ordering::SeqCst);
    }

    #[test]
    fn analysis_prewarm_missing_package_config_releases_flag() {
        let _guard = PREWARM_TEST_LOCK.lock().unwrap();
        let root = std::env::temp_dir()
            .join(format!("build-runner-accelerator-prewarm-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        assert!(spawn_analysis_prewarm(&root, "dart", "test").is_none());
        assert!(!ANALYSIS_PREWARM_ACTIVE.load(Ordering::SeqCst));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn analysis_prewarm_enabled_follows_env() {
        let _guard = PREWARM_TEST_LOCK.lock().unwrap();
        let name = "BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM";
        let saved = std::env::var_os(name);
        // SAFETY: env mutation is unsafe in edition 2024; PREWARM_TEST_LOCK
        // serializes every test in this module that touches the environment.
        unsafe {
            std::env::remove_var(name);
            assert!(analysis_prewarm_enabled());
            std::env::set_var(name, "0");
            assert!(!analysis_prewarm_enabled());
            std::env::set_var(name, "off");
            assert!(!analysis_prewarm_enabled());
            match saved {
                Some(value) => std::env::set_var(name, value),
                None => std::env::remove_var(name),
            }
        }
    }
}
