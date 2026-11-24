use super::lock::{
    AOT_COMPILE_WAIT_MAX, BackgroundAotLock, acquire_background_aot_lock, aot_compile_lock_path,
    background_aot_lock_owned, wait_for_aot_winner,
};
use super::policy::{
    BACKGROUND_AOT_AFTER_EXIT_ENV, BACKGROUND_AOT_HELPER_ENV, BACKGROUND_AOT_LOCK_ENV,
    BACKGROUND_AOT_SPAWNER_ENV, compile_prewarm_enabled, sdk_summary_prewarm_enabled,
};
use super::shared_cache::{
    aot_cache_key_with_worker_digest, aot_metadata_is_current, build_aot_metadata,
    build_kernel_stamp, digest_file, kernel_package_config_key, kernel_stamp_is_current,
    publish_shared_aot, restore_shared_aot,
};
use super::{spawn_analysis_prewarm, spawn_analysis_prewarm_options};
use crate::workspace::{Workspace, canonicalize};
use std::env;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Instant;

pub(super) struct AotContext {
    pub(super) workspace: Workspace,
    pub(super) sdk_root: PathBuf,
    pub(super) worker_path: PathBuf,
    /// Digest of the worker source the cache key was computed from;
    /// a compile binds its input to this digest (see
    /// [`WorkerSourceSnapshot`]).
    pub(super) worker_digest: String,
    pub(super) cache_key: String,
    pub(super) aot_sdk_root: PathBuf,
    pub(super) aot_path: PathBuf,
    pub(super) depfile_path: PathBuf,
    pub(super) sdk_metadata_path: PathBuf,
}

/// A compile-only snapshot in the selected config's directory: relative URIs
/// retain their base. Unique exclusive creation prevents competing preparations
/// from rewriting this compiler's inputs; no cache-hit I/O is added.
/// The `._` prefix uses the existing source-discovery exclusion, so a killed
/// compiler cannot leave a snapshot that later becomes a builder input.
pub(super) struct CompilerConfigSnapshot {
    pub(super) path: PathBuf,
}

impl CompilerConfigSnapshot {
    pub(super) fn create(workspace: &Workspace) -> io::Result<Self> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let (selected, contents) = workspace.compiler_package_config();
        let parent = selected
            .parent()
            .ok_or_else(|| io::Error::other("compiler package configuration has no parent"))?;
        loop {
            let path = parent.join(format!(
                "._worker-aot-packages-{}-{}.json",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed),
            ));
            let mut file = match create_compiler_config(&path) {
                Ok(file) => file,
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            };
            let snapshot = Self { path };
            let result = file
                .write_all(contents.as_bytes())
                .and_then(|()| file.flush());
            drop(file);
            result?;
            return Ok(snapshot);
        }
    }
}

#[cfg(not(windows))]
fn create_compiler_config(path: &Path) -> io::Result<fs::File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

#[cfg(windows)]
use super::windows::create_compiler_config;

impl Drop for CompilerConfigSnapshot {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

/// A compile-only snapshot of the worker source, taken next to the
/// source itself so relative URIs retain their base. A background
/// helper compiles after the build that selected the worker has
/// exited, when nothing else coordinates the entrypoint: a later
/// build can regenerate it under a different configuration while
/// the compile runs. Compiling this snapshot binds the published
/// executable and its metadata to the exact bytes the context's
/// cache key was computed from. The `._` prefix uses the existing
/// source-discovery exclusion, so a killed compiler cannot leave
/// a snapshot that later becomes a builder input.
struct WorkerSourceSnapshot {
    path: PathBuf,
}

impl WorkerSourceSnapshot {
    fn create(worker_path: &Path) -> io::Result<Self> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let contents = fs::read(worker_path)?;
        let parent = worker_path
            .parent()
            .ok_or_else(|| io::Error::other("worker entrypoint has no parent directory"))?;
        loop {
            let path = parent.join(format!(
                "._worker-aot-source-{}-{}.dart",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed),
            ));
            let mut file = match create_compiler_config(&path) {
                Ok(file) => file,
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            };
            let snapshot = Self { path };
            let result = file.write_all(&contents).and_then(|()| file.flush());
            drop(file);
            result?;
            return Ok(snapshot);
        }
    }
}

impl Drop for WorkerSourceSnapshot {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub(super) fn prepare_aot_context(
    workspace: &Workspace,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<AotContext> {
    let root = &workspace.root;
    let worker_path = absolute_worker_path(root, Path::new(worker_executable))?;
    let sdk_root = dart_sdk_root(dart_binary)?;
    // One read of the worker source feeds both the context's digest
    // and the cache key, so the snapshot check in prepare_worker_aot
    // binds the compile to exactly the key it publishes under.
    let worker_digest = digest_file(&worker_path)?;
    let cache_key = aot_cache_key_with_worker_digest(workspace, &worker_digest, &sdk_root)?;
    let aot_sdk_root = worker_path
        .parent()
        .ok_or_else(|| io::Error::other("worker entrypoint has no parent directory"))?
        .join("aot-sdk");
    let aot_bin = aot_sdk_root.join("bin");
    let aot_path = aot_bin.join(aot_file_name(&worker_path));
    if sdk_root
        .join("bin")
        .join(aot_file_name(&worker_path))
        .exists()
    {
        return Err(io::Error::other(
            "Unsupported worker executable name conflicts with an SDK bin entry",
        ));
    }
    fs::create_dir_all(&aot_bin)?;
    link_sdk_entry(&sdk_root, &aot_sdk_root, "lib")?;
    link_sdk_entry(&sdk_root, &aot_sdk_root, "version")?;
    // Builders locate compiler executables and snapshots relative to the
    // running worker. Keep the real SDK bin entries alongside our AOT binary
    // so subprocesses see the same SDK as library/summary readers.
    link_sdk_bin(&sdk_root, &aot_sdk_root)?;
    // Flutter keeps dart:ui outside the Dart SDK root at
    // `<cache>/pkg/sky_engine`. Mirror it next to `aot-sdk` so lookups
    // relative to `Platform.resolvedExecutable` (e.g. build_runner's
    // `isFlutter` detection when generating the SDK summary) still work
    // inside the self-contained worker executable.
    if let (Some(sdk_parent), Some(aot_parent)) = (sdk_root.parent(), aot_sdk_root.parent())
        && sdk_parent.join("pkg").is_dir()
    {
        link_sdk_entry(sdk_parent, aot_parent, "pkg")?;
    }
    let depfile_path = PathBuf::from(format!("{}.d", aot_path.display()));
    let sdk_metadata_path = PathBuf::from(format!("{}.sdk", aot_path.display()));
    Ok(AotContext {
        workspace: workspace.clone(),
        sdk_root,
        worker_path,
        worker_digest,
        cache_key,
        aot_sdk_root,
        aot_path,
        depfile_path,
        sdk_metadata_path,
    })
}

pub(super) fn current_aot_from_context(context: &AotContext) -> io::Result<Option<PathBuf>> {
    if aot_metadata_is_current(
        &context.aot_path,
        &context.sdk_metadata_path,
        &context.workspace,
        &context.sdk_root,
        &context.worker_path,
        &context.cache_key,
    ) {
        return Ok(Some(canonicalize(&context.aot_path)?));
    }
    Ok(None)
}

pub(super) fn prepare_worker_aot(
    workspace: &Workspace,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<PathBuf> {
    let context = prepare_aot_context(workspace, dart_binary, worker_executable)?;
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
    let wait_deadline = Instant::now() + AOT_COMPILE_WAIT_MAX;
    if let Some(lock_path) = &lock_path
        && let Some(aot) = wait_for_aot_winner(&context, lock_path, wait_deadline)?
    {
        return Ok(aot);
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
                match wait_for_aot_winner(&context, lock_path, wait_deadline)? {
                    Some(aot) => return Ok(aot),
                    None => None,
                }
            }
        }
        _ => None,
    };

    // The previous owner may have published and released the lock between
    // our cache check and acquisition. Recheck before starting a compiler.
    if let Some(aot) = current_aot_from_context(&context)? {
        return Ok(aot);
    }
    if let Ok(Some(aot)) = restore_shared_aot(&context) {
        return Ok(aot);
    }

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
    let package_config = CompilerConfigSnapshot::create(&context.workspace)?;
    // Compile a snapshot of the generated worker source, bound to
    // the digest the cache key was computed from: the generated
    // entrypoint can be regenerated while a background compile
    // runs, and publishing an executable compiled from different
    // bytes under this key would validate against the wrong
    // catalog. Explicit worker overrides are user-managed files
    // that no other build rewrites, and renaming one would change
    // its library URI, so those compile from their real path.
    let source_snapshot = if context.worker_path
        == context
            .workspace
            .root
            .join(crate::frontend::WORKER_ENTRYPOINT_PATH)
    {
        let snapshot = WorkerSourceSnapshot::create(&context.worker_path)?;
        if digest_file(&snapshot.path)? != context.worker_digest {
            return Err(io::Error::other(
                "worker source changed while preparing the AOT compile",
            ));
        }
        Some(snapshot)
    } else {
        None
    };
    let compiled_worker_path = source_snapshot
        .as_ref()
        .map_or(&context.worker_path, |snapshot| &snapshot.path);
    let compile_start = Instant::now();
    let output = Command::new(dart_binary)
        .args(["--suppress-analytics", "compile", "exe"])
        .arg(format!("--packages={}", package_config.path.display()))
        .arg(format!("--depfile={}", temp_depfile.display()))
        .arg(compiled_worker_path)
        .arg("-o")
        .arg(&temp_aot)
        .current_dir(&context.workspace.root)
        .output()
        .map_err(|error| aot_compile_error(&context.worker_path, error))?;
    relay_compiler_stderr(&output.stderr);
    drop(analysis_prewarm);
    if env::var("BUILD_RUNNER_ACCELERATOR_METRICS").as_deref() == Ok("1") {
        eprintln!(
            "Rust worker AOT compile: elapsed_us={}",
            compile_start.elapsed().as_micros()
        );
    }
    if !output.status.success() {
        remove_if_present(&temp_aot);
        remove_if_present(&temp_depfile);
        remove_if_present(&temp_sdk_metadata);
        return Err(aot_compile_status_error(
            &context.worker_path,
            output.status,
        ));
    }

    let metadata = build_aot_metadata(
        &context.workspace,
        &context.sdk_root,
        &context.worker_path,
        compiled_worker_path,
        &package_config.path,
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
    canonicalize(context.aot_path)
}

pub(super) fn spawn_background_worker_aot(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
    context: &AotContext,
    after_exit: bool,
) -> io::Result<bool> {
    let lock_path = aot_compile_lock_path(context)
        .ok_or_else(|| io::Error::other("AOT SDK directory has no parent"))?;
    // An after-exit helper acquires the lock itself once the spawner has
    // exited: holding it during the wait would leave a fresh-looking
    // stale lock behind if the helper is killed with its build, and
    // would block a retry on an artifact nobody is compiling.
    if !after_exit && !acquire_background_aot_lock(&lock_path)? {
        return Ok(false);
    }

    let current_exe = match env::current_exe() {
        Ok(path) => path,
        Err(error) => {
            if !after_exit {
                remove_if_present(&lock_path);
            }
            return Err(error);
        }
    };
    let mut command = Command::new(current_exe);
    command
        .args(["prewarm", "--root"])
        .arg(root)
        .args(["--dart"])
        .arg(dart_binary)
        .args(["--worker"])
        .arg(worker_executable)
        .current_dir(root)
        .env(BACKGROUND_AOT_LOCK_ENV, &lock_path)
        .env(BACKGROUND_AOT_HELPER_ENV, "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if after_exit {
        command
            .env(BACKGROUND_AOT_AFTER_EXIT_ENV, "1")
            .env(BACKGROUND_AOT_SPAWNER_ENV, std::process::id().to_string());
    }
    let result = command.spawn();
    match result {
        Ok(mut child) => {
            // Reap the helper while the foreground process remains alive
            // (notably during watch). If the foreground process exits first,
            // the child can finish after a successful exit. Cancellation/failure
            // remains covered by the inherited supervisor group/job.
            thread::spawn(move || {
                let _ = child.wait();
            });
            Ok(true)
        }
        Err(error) => {
            // An after-exit spawn never acquired the lock; it may belong
            // to another compile in progress.
            if !after_exit {
                remove_if_present(&lock_path);
            }
            Err(error)
        }
    }
}

fn dart_sdk_root(dart_binary: &str) -> io::Result<PathBuf> {
    if let Some(value) = env::var_os("DART_SDK") {
        let path = PathBuf::from(value);
        if path.join("lib").is_dir() {
            return canonicalize(path);
        }
    }

    dart_sdk_root_for_binary(dart_binary)
}

// Generator kernels must match the VM that will execute them, even when an
// independent DART_SDK override is used for worker AOT preparation.
pub(crate) fn dart_sdk_root_for_binary(dart_binary: &str) -> io::Result<PathBuf> {
    let dart_path = if Path::new(dart_binary).is_absolute()
        || Path::new(dart_binary)
            .parent()
            .is_some_and(|parent| !parent.as_os_str().is_empty())
    {
        PathBuf::from(dart_binary)
    } else {
        find_on_path(dart_binary)?
    };
    let dart_path = canonicalize(dart_path)?;
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

pub(super) fn link_sdk_bin(sdk_root: &Path, aot_sdk_root: &Path) -> io::Result<()> {
    // Keep ownership evidence across SDK switches, including partial failures.
    // Only links we created may be removed; worker binaries and user files stay.
    static LINKS_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = LINKS_LOCK
        .lock()
        .map_err(|_| io::Error::other("SDK bin link lock poisoned"))?;
    // Keep the lock file in place so every process locks the same inode.
    // Hold the OS lock through both registry updates and link mutations.
    let registry_lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(aot_sdk_root.join("sdk-bin-links.lock"))?;
    registry_lock.lock()?;
    let registry = aot_sdk_root.join("sdk-bin-links.json");
    let mut owned: Vec<PathBuf> = match fs::read(&registry) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(io::Error::other)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(error),
    };
    prune_sdk_bin_links(aot_sdk_root, &registry, &mut owned)?;
    let mut entries = fs::read_dir(sdk_root.join("bin"))?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<io::Result<Vec<_>>>()?;
    entries.sort();
    for entry in fs::read_dir(aot_sdk_root.join("bin"))? {
        let entry = entry?;
        if entries.contains(&entry.file_name()) {
            continue;
        }
        if let Ok(target) = fs::read_link(entry.path())
            && target.file_name() == Some(entry.file_name().as_os_str())
            && owned.contains(&target)
        {
            remove_sdk_link(&entry.path())?;
            prune_sdk_bin_links(aot_sdk_root, &registry, &mut owned)?;
        }
    }
    for name in entries {
        let source = sdk_root.join("bin").join(&name);
        let new_claim = !owned.contains(&source);
        if new_claim {
            // Write ahead so an interrupted setup can recognize its links.
            owned.push(source);
            owned.sort();
            write_sdk_bin_registry(&registry, &owned)?;
        }
        let result = link_sdk_entry(sdk_root, aot_sdk_root, Path::new("bin").join(name));
        if new_claim || result.is_err() {
            // Forget replaced links and failed intents, including on errors.
            prune_sdk_bin_links(aot_sdk_root, &registry, &mut owned)?;
        }
        result?;
    }
    Ok(())
}

fn prune_sdk_bin_links(facade: &Path, registry: &Path, owned: &mut Vec<PathBuf>) -> io::Result<()> {
    let mut active = Vec::new();
    for target in owned.iter() {
        let Some(name) = target.file_name() else {
            continue;
        };
        let link = facade.join("bin").join(name);
        let metadata = match fs::symlink_metadata(&link) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        if metadata.file_type().is_symlink() && fs::read_link(link)? == *target {
            active.push(target.clone());
        }
    }
    if active != *owned {
        write_sdk_bin_registry(registry, &active)?;
        *owned = active;
    }
    Ok(())
}

fn write_sdk_bin_registry(registry: &Path, owned: &[PathBuf]) -> io::Result<()> {
    let temporary = temporary_sibling(registry, std::process::id(), "links");
    fs::write(
        &temporary,
        serde_json::to_vec(owned).map_err(io::Error::other)?,
    )?;
    replace_file(&temporary, registry)
}

fn remove_sdk_link(path: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::fs::FileTypeExt;
        if fs::symlink_metadata(path)?.file_type().is_symlink_dir() {
            return fs::remove_dir(path);
        }
    }
    fs::remove_file(path)
}

fn link_sdk_entry(sdk_root: &Path, aot_sdk_root: &Path, name: impl AsRef<Path>) -> io::Result<()> {
    let source = sdk_root.join(name.as_ref());
    if !source.exists() {
        return Err(io::Error::other(format!(
            "Dart SDK entry not found: {}",
            source.display()
        )));
    }
    let destination = aot_sdk_root.join(name.as_ref());
    if let Ok(existing) = fs::read_link(&destination) {
        let existing = if existing.is_absolute() {
            existing
        } else {
            destination
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .join(existing)
        };
        if canonicalize(existing).ok() == canonicalize(&source).ok() {
            return Ok(());
        }
        // A concurrent compile can remove or recreate the same link.
        if let Err(error) = remove_sdk_link(&destination)
            && error.kind() != io::ErrorKind::NotFound
        {
            return Err(error);
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
        if error.kind() == io::ErrorKind::AlreadyExists
            && let Ok(existing) = fs::read_link(&destination)
        {
            let existing = if existing.is_absolute() {
                existing
            } else {
                destination
                    .parent()
                    .unwrap_or_else(|| Path::new("."))
                    .join(existing)
            };
            if canonicalize(existing).ok() == canonicalize(&source).ok() {
                return Ok(());
            }
        }
        return Err(error);
    }
    Ok(())
}

pub(super) fn prepare_worker_kernel(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<PathBuf> {
    let worker_path = absolute_worker_path(root, Path::new(worker_executable))?;
    let kernel_path = worker_path.with_extension("dill");
    let depfile_path = PathBuf::from(format!("{}.d", kernel_path.display()));
    // The stamp binds the SDK of the binary that compiles and launches
    // the kernel, not the DART_SDK override used for AOT preparation.
    if dart_sdk_root_for_binary(dart_binary).is_ok_and(|sdk_root| {
        kernel_stamp_is_current(root, &sdk_root, &kernel_path, &depfile_path, &worker_path)
    }) {
        return canonicalize(kernel_path);
    }

    let process_id = std::process::id();
    let temp_kernel = temporary_sibling(&kernel_path, process_id, "dill");
    let temp_depfile = temporary_sibling(&depfile_path, process_id, "d");
    let package_config = crate::runner_compatibility::package_config(root)?;
    let config_key = kernel_package_config_key(&package_config)?;
    let compile_started = std::time::SystemTime::now();
    let output = Command::new(dart_binary)
        .args(["--suppress-analytics", "compile", "kernel"])
        .arg("--no-embed-sources")
        .arg(format!("--packages={}", package_config.display()))
        .arg(format!("--depfile={}", temp_depfile.display()))
        .arg(&worker_path)
        .arg("-o")
        .arg(&temp_kernel)
        .current_dir(root)
        .output()
        .map_err(|error| kernel_compile_error(&worker_path, error))?;
    relay_compiler_stderr(&output.stderr);
    if !output.status.success() {
        remove_if_present(&temp_kernel);
        remove_if_present(&temp_depfile);
        return Err(kernel_compile_status_error(&worker_path, output.status));
    }
    let current_config_key = crate::runner_compatibility::package_config(root)
        .and_then(|path| kernel_package_config_key(&path));
    if !current_config_key.is_ok_and(|key| key == config_key) {
        remove_if_present(&temp_kernel);
        remove_if_present(&temp_depfile);
        return Err(io::Error::other(
            "kernel package configuration changed during compilation",
        ));
    }
    let config_stamp = kernel_path.with_extension("dill.config");
    let temp_config = temporary_sibling(&config_stamp, process_id, "config");
    let stamp_json = match dart_sdk_root_for_binary(dart_binary)
        .and_then(|sdk_root| {
            build_kernel_stamp(
                root,
                &sdk_root,
                &temp_kernel,
                &temp_depfile,
                &config_key,
                compile_started,
            )
        })
        .and_then(|stamp| serde_json::to_string(&stamp).map_err(io::Error::other))
    {
        Ok(json) => json,
        Err(error) => {
            remove_if_present(&temp_kernel);
            remove_if_present(&temp_depfile);
            return Err(error);
        }
    };
    if let Err(error) = fs::write(&temp_config, stamp_json) {
        remove_if_present(&temp_kernel);
        remove_if_present(&temp_depfile);
        return Err(error);
    }

    // Publish the dependency list before the kernel. If the second rename is
    // interrupted, the old kernel is conservatively treated as stale.
    // An interrupted replacement must not leave the new kernel paired with
    // the previous compilation's stamp either.
    match fs::remove_file(&config_stamp) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    replace_file(&temp_depfile, &depfile_path)?;
    replace_file(&temp_kernel, &kernel_path)?;
    replace_file(&temp_config, &config_stamp)?;
    canonicalize(kernel_path)
}

pub(super) fn absolute_worker_path(root: &Path, worker_path: &Path) -> io::Result<PathBuf> {
    let path = if worker_path.is_absolute() {
        worker_path.to_path_buf()
    } else {
        root.join(worker_path)
    };
    canonicalize(path)
}

pub(super) fn temporary_sibling(path: &Path, process_id: u32, extension: &str) -> PathBuf {
    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("worker-cache");
    path.with_file_name(format!(".{filename}.{process_id}.tmp.{extension}"))
}

pub(super) fn replace_file(source: &Path, destination: &Path) -> io::Result<()> {
    #[cfg(windows)]
    if destination.exists() {
        fs::remove_file(destination)?;
    }
    fs::rename(source, destination)
}

pub(super) fn remove_if_present(path: &Path) {
    let _ = fs::remove_file(path);
}

/// Relays captured compiler diagnostics to this process's stderr.
///
/// Worker compiles capture the compiler's output instead of inheriting it
/// because `dart compile` prints a `Generated: ...` line naming the
/// temporary artifact (renamed before use) on stdout, which is internal
/// noise in the build output. Only stdout is suppressed: the captured
/// stderr is relayed on success and failure alike, preserving the
/// diagnostics and warnings the inherited stream used to show.
fn relay_compiler_stderr(stderr: &[u8]) {
    use std::io::Write;
    let mut err = io::stderr().lock();
    let _ = err.write_all(stderr);
    let _ = err.flush();
}

fn kernel_compile_error(worker: &Path, error: io::Error) -> io::Error {
    io::Error::new(
        error.kind(),
        format!(
            "failed to compile worker kernel for {}: {error}",
            worker.display()
        ),
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
        format!(
            "failed to compile worker AOT executable for {}: {error}",
            worker.display()
        ),
    )
}

fn aot_compile_status_error(worker: &Path, status: std::process::ExitStatus) -> io::Error {
    io::Error::other(format!(
        "worker AOT compilation exited with {status}: {}",
        worker.display()
    ))
}
