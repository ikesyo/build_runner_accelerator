mod compile;
mod lock;
mod policy;
mod shared_cache;
#[cfg(test)]
mod tests;
#[cfg(windows)]
mod windows;

pub(crate) use compile::dart_sdk_root_for_binary;
#[allow(unused_imports)] // Preserve the existing crate::worker_kernel::BackgroundAotLock path.
pub(crate) use lock::BackgroundAotLock;
pub(crate) use lock::{
    AOT_COMPILE_LOCK_NAME, acquire_background_aot_lock, acquire_deferred_background_aot_lock,
    take_background_aot_lock, wait_for_background_spawner_exit,
};
#[allow(unused_imports)]
// Preserve the existing crate::worker_kernel::BACKGROUND_AOT_SPAWNER_ENV path.
pub(crate) use policy::BACKGROUND_AOT_SPAWNER_ENV;
pub(crate) use policy::{
    BACKGROUND_AOT_AFTER_EXIT_ENV, BACKGROUND_AOT_HELPER_ENV, BACKGROUND_AOT_LOCK_ENV,
    analysis_prewarm_enabled, apply_default_worker_aot_policy, background_aot_requested,
    env_flag_disabled, manifest_prewarm_enabled,
};
#[cfg(test)]
pub(crate) use shared_cache::aot_cache_key;
pub(crate) use shared_cache::{aot_sdk_identity, parse_depfile_dependencies, shared_cache_root};

use compile::{
    absolute_worker_path, current_aot_from_context, prepare_aot_context, prepare_worker_aot,
    prepare_worker_kernel, replace_file, spawn_background_worker_aot,
};
use policy::{
    AotRequest, aot_request, configured_worker_aot, configured_worker_kernel, prewarm_jobs,
};
use shared_cache::{kernel_stamp_is_current, restore_shared_aot};

use crate::workspace::{Workspace, canonicalize};
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum WorkerArtifact {
    Script,
    Kernel(PathBuf),
    Aot(PathBuf),
}

/// Select the worker launch artifact using this build's prepared resolution.
/// Callers load a fresh Workspace at command/watch configuration boundaries;
/// AOT helpers must not reload it within that preparation unit.
///
/// The launcher requests a synchronous AOT worker for one-shot commands and
/// a background compile for `watch` by default. A synchronous request starts
/// on a cached AOT artifact when one exists; on a cold cache it starts on a
/// kernel worker and compiles AOT in the background for the next build. The
/// request can be disabled, made synchronous, or made strict through the
/// environment. An explicit AOT path takes precedence over every other mode.
///
pub(crate) fn resolve_worker_artifact(
    workspace: &Workspace,
    dart_binary: &str,
    worker_executable: &str,
    auto: bool,
) -> io::Result<WorkerArtifact> {
    let root = &workspace.root;
    if let Some(aot) = configured_worker_aot()? {
        return Ok(WorkerArtifact::Aot(aot));
    }
    if auto && is_dart_source(worker_executable) {
        match aot_request() {
            AotRequest::Force => {
                let aot = prepare_worker_aot(workspace, dart_binary, worker_executable)?;
                return Ok(WorkerArtifact::Aot(aot));
            }
            AotRequest::Synchronous => {
                // An explicit kernel artifact wins over the automatic
                // synchronous compile. `force` remains strict above.
                if let Some(kernel) = configured_worker_kernel()? {
                    return Ok(WorkerArtifact::Kernel(kernel));
                }
                match current_or_restored_aot(workspace, dart_binary, worker_executable) {
                    Ok(Some(aot)) => return Ok(WorkerArtifact::Aot(aot)),
                    Ok(None) => {
                        // Cold cache: a synchronous AOT compile blocks the
                        // first action for tens of seconds, while a kernel
                        // compile is several times faster and its workers
                        // start quickly. Start on the kernel and let the AOT
                        // compile finish in the background; it publishes to
                        // the shared cache so the next build starts on AOT.
                        // The helper starts only once the kernel is ready:
                        // if kernel preparation failed, the synchronous AOT
                        // fallback below would wait on the compile lock the
                        // helper holds while the helper waits for this
                        // process to exit.
                        // Under workspace-mode state the helper cannot run
                        // (it is rejected as an individual invocation), so
                        // those builds keep the synchronous compile below
                        // until the helper has a workspace-aware path.
                        // Platforms without a liveness probe spawn no
                        // helper at all and also keep the synchronous
                        // compile, so their AOT cache still gets populated.
                        if cfg!(unix)
                            && crate::workspace_mode::reject_individual_after_workspace(root)
                                .is_ok()
                            && !pub_workspace_participant(root)
                        {
                            match prepare_worker_kernel(root, dart_binary, worker_executable) {
                                Ok(kernel) => {
                                    start_background_aot_compile(
                                        workspace,
                                        dart_binary,
                                        worker_executable,
                                        "kernel",
                                    );
                                    return Ok(WorkerArtifact::Kernel(kernel));
                                }
                                Err(error) => {
                                    eprintln!(
                                        "Rust worker kernel cache unavailable; compiling AOT synchronously ({error})"
                                    );
                                }
                            }
                        }
                        match prepare_worker_aot(workspace, dart_binary, worker_executable) {
                            Ok(aot) => return Ok(WorkerArtifact::Aot(aot)),
                            Err(error) => {
                                eprintln!(
                                    "Rust worker AOT cache unavailable; using Dart script ({error})"
                                );
                                return Ok(WorkerArtifact::Script);
                            }
                        }
                    }
                    Err(error) => {
                        // The probe itself failed (for example a broken SDK
                        // layout); keep the previous blocking behavior.
                        eprintln!(
                            "Rust worker AOT cache check failed; compiling synchronously ({error})"
                        );
                        match prepare_worker_aot(workspace, dart_binary, worker_executable) {
                            Ok(aot) => return Ok(WorkerArtifact::Aot(aot)),
                            Err(error) => {
                                eprintln!(
                                    "Rust worker AOT cache unavailable; using kernel/script ({error})"
                                );
                            }
                        }
                    }
                }
            }
            AotRequest::Background => {
                // An explicit kernel artifact wins over the automatic
                // background selection and its cached-AOT result.
                if let Some(kernel) = configured_worker_kernel()? {
                    return Ok(WorkerArtifact::Kernel(kernel));
                }
                match prepare_aot_context(workspace, dart_binary, worker_executable)
                    .and_then(|context| {
                        if let Some(aot) = current_aot_from_context(&context)? {
                            return Ok(Some(aot));
                        }
                        let started = spawn_background_worker_aot(
                            root,
                            dart_binary,
                            worker_executable,
                            &context,
                            false,
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
            eprintln!("Rust worker kernel cache unavailable; using Dart script ({error})");
            Ok(WorkerArtifact::Script)
        }
    }
}

pub(crate) fn prewarm_worker_aot(
    workspace: &Workspace,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<PathBuf> {
    if !is_dart_source(worker_executable) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "AOT prewarm requires a Dart worker source",
        ));
    }
    prepare_worker_aot(workspace, dart_binary, worker_executable)
}

/// Whether [root] takes part in a Pub workspace, as a member or as
/// the workspace root. The after-exit helper holds the shared
/// coordination lock at the workspace root for the length of its
/// compile, and a workspace build takes that lock exclusively, so a
/// leftover helper would make the next workspace build fail. A build
/// in a workspace keeps the synchronous compile instead; the helper
/// is reserved for standalone packages, where the shared lock
/// conflicts only with an explicit prewarm.
fn pub_workspace_participant(root: &Path) -> bool {
    match crate::workspace_mode::coordination_root(root) {
        Ok(coordination) => {
            if coordination != root {
                return true;
            }
        }
        Err(_) => return true,
    }
    let pubspec = root.join("pubspec.yaml");
    crate::workspace_discovery::pubspec_opts_into_workspace(&pubspec).unwrap_or(true)
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
    workspace: &Workspace,
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
    // The thread is joined by frontend preparation before this unit ends.
    // Clone the validated workspace, never carry it into the detached helper.
    let workspace = workspace.clone();
    let dart_binary = dart_binary.to_string();
    let worker_executable = worker_executable.to_string();
    let readiness = readiness.map(Path::to_path_buf);
    let source = fs::read_to_string(&worker_executable).ok();
    Some(thread::spawn(move || {
        // A panic must also settle the invocation-local readiness marker.
        // Otherwise the Dart generator can wait the full readiness timeout
        // before it falls back to the source probe.
        let result = catch_worker_aot_panic(|| {
            prepare_worker_aot(&workspace, &dart_binary, &worker_executable)
        });
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

/// Whether the manifest-generation window starts the worker AOT compile
/// early (see [`early_worker_aot_compile`]): the synchronous and force
/// policies, unless an explicit AOT or kernel artifact is configured.
/// The compile serves the manifest probe; when it produces an artifact,
/// the build reuses it. When it does not (no manifest generation ran, or
/// the compile was unavailable), `resolve_worker_artifact` starts the
/// build on a kernel worker instead of compiling synchronously.
pub(crate) fn early_worker_aot_enabled() -> bool {
    matches!(aot_request(), AotRequest::Synchronous | AotRequest::Force)
        && configured_worker_aot().ok().flatten().is_none()
        && configured_worker_kernel().ok().flatten().is_none()
}

/// Spawn JIT `AnalysisDriver` processes that resolve the workspace package's
/// sources into the shared byte store, priming both cold-start caches in one
/// `prewarm` step. The caller joins with [`AnalysisPrewarm::wait_for_children`];
/// `None` means the shared byte store is disabled, the accelerator package
/// cannot be located, the workspace has no package config yet, or another
/// prewarm window already owns the shards.
pub(crate) fn start_analysis_prewarm(root: &Path, dart_binary: &str) -> Option<AnalysisPrewarm> {
    spawn_analysis_prewarm(root, dart_binary, "prewarm")
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

/// Checks whether a pinned compiled worker still matches its current inputs.
/// Script workers are deliberately treated as current so a watch session does
/// not switch to an AOT worker that finished compiling after the session began.
pub(crate) fn pinned_worker_artifact_is_current(
    workspace: &Workspace,
    dart_binary: &str,
    worker_executable: &str,
    artifact: &WorkerArtifact,
) -> io::Result<bool> {
    let root = &workspace.root;
    match artifact {
        WorkerArtifact::Script => Ok(true),
        WorkerArtifact::Aot(path) => {
            if let Some(configured) = configured_worker_aot()? {
                return Ok(configured.as_path() == path.as_path());
            }
            let context = prepare_aot_context(workspace, dart_binary, worker_executable)?;
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
            if !dart_sdk_root_for_binary(dart_binary).is_ok_and(|sdk_root| {
                kernel_stamp_is_current(root, &sdk_root, &kernel_path, &depfile_path, &worker_path)
            }) {
                return Ok(false);
            }
            Ok(canonicalize(kernel_path)?.as_path() == path.as_path())
        }
    }
}

pub(crate) fn background_worker_aot_if_ready(
    workspace: &Workspace,
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
    let context = prepare_aot_context(workspace, dart_binary, worker_executable)?;
    current_aot_from_context(&context)
}

/// Probe for an already-compiled AOT artifact for this worker: the
/// workspace-local slot first, then the machine-wide shared cache. Never
/// compiles; a miss returns `Ok(None)`.
fn current_or_restored_aot(
    workspace: &Workspace,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<Option<PathBuf>> {
    let context = prepare_aot_context(workspace, dart_binary, worker_executable)?;
    if let Some(aot) = current_aot_from_context(&context)? {
        return Ok(Some(aot));
    }
    restore_shared_aot(&context)
}

/// Kick off the background AOT compile for a cold cache, mirroring the
/// messages the background policy prints. Failures are reported and
/// swallowed: the caller proceeds on a fallback artifact either way.
fn start_background_aot_compile(
    workspace: &Workspace,
    dart_binary: &str,
    worker_executable: &str,
    fallback: &str,
) {
    // The helper defers its compile until the spawning process exits;
    // that wait needs a process-liveness probe, implemented only on
    // unix. Elsewhere the helper would compile alongside the build it
    // is meant to stay out of the way of, so no helper is started.
    #[cfg(not(unix))]
    {
        let _ = (workspace, dart_binary, worker_executable, fallback);
    }
    #[cfg(unix)]
    {
        let root = &workspace.root;
        match prepare_aot_context(workspace, dart_binary, worker_executable).and_then(|context| {
            spawn_background_worker_aot(root, dart_binary, worker_executable, &context, true)
        }) {
            Ok(true) => eprintln!(
                "Rust worker AOT cache miss; using {fallback} while AOT compiles in background"
            ),
            Ok(false) => {
                eprintln!("Rust worker AOT compile is already running; using {fallback}")
            }
            Err(error) => {
                eprintln!("Rust worker background AOT unavailable; using {fallback} ({error})")
            }
        }
    }
}

/// JIT analyzer prewarm spawned by `prewarm` to fill the shared byte
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

fn prewarm_script_path(root: &Path) -> Option<PathBuf> {
    // The compiler view may copy only lib/. Locate the orchestration helper
    // in the original package, then compile it with the effective config.
    let config_path = crate::workspace_discovery::pub_resolution_root(root)
        .ok()?
        .join(".dart_tool/package_config.json");
    let text = fs::read_to_string(&config_path).ok()?;
    let config: serde_json::Value = serde_json::from_str(&text).ok()?;
    let package = config.get("packages")?.as_array()?.iter().find(|package| {
        package.get("name").and_then(|name| name.as_str()) == Some("build_runner_accelerator")
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
        if bytes[index] == b'%'
            && index + 2 < bytes.len()
            && let (Some(high), Some(low)) =
                (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
        {
            out.push(high * 16 + low);
            index += 3;
            continue;
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
    let Ok(package_config) = crate::runner_compatibility::package_config(root) else {
        ANALYSIS_PREWARM_ACTIVE.store(false, Ordering::Release);
        return None;
    };
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
