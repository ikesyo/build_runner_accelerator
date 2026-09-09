use crate::digest::digest_bytes;
use crate::workspace::Workspace;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

const AOT_METADATA_VERSION: u32 = 2;
const AOT_CACHE_KEY_VERSION: &str = "v2";
const BACKGROUND_AOT_LOCK_ENV: &str = "BUILD_RUNNER_ACCELERATOR_WORKER_AOT_BACKGROUND_LOCK";
const BACKGROUND_AOT_LOCK_MAX_AGE: Duration = Duration::from_secs(60 * 60);

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
    dependencies: BTreeMap<String, String>,
}

/// Select the worker launch artifact.
///
/// The generated worker remains script-based by default. A kernel cache is
/// still the normal automatic optimization, while the AOT executable cache is
/// opt-in until its platform and memory trade-offs have been measured in more
/// workspaces. An explicit AOT path takes precedence over every other mode.
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
            AotRequest::Synchronous => match prepare_worker_aot(root, dart_binary, worker_executable)
            {
                Ok(aot) => return Ok(WorkerArtifact::Aot(aot)),
                Err(error) => {
                    eprintln!(
                        "Rust worker AOT cache unavailable; using kernel/script ({error})"
                    );
                }
            },
            AotRequest::Background => {
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

fn aot_request() -> AotRequest {
    let Ok(value) = env::var("BUILD_RUNNER_ACCELERATOR_WORKER_AOT") else {
        return AotRequest::Disabled;
    };
    match value.to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "auto" => AotRequest::Synchronous,
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

pub(crate) fn background_worker_aot_if_ready(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<Option<PathBuf>> {
    if !background_aot_requested() || !is_dart_source(worker_executable) {
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

    let process_id = std::process::id();
    let temp_aot = temporary_sibling(&context.aot_path, process_id, "aot");
    let temp_depfile = temporary_sibling(&context.depfile_path, process_id, "d");
    let temp_sdk_metadata = temporary_sibling(&context.sdk_metadata_path, process_id, "sdk");
    let package_config = context.workspace.root.join(".dart_tool/package_config.json");
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
        &context.cache_key,
    )?;
    fs::write(&temp_sdk_metadata, serde_json::to_vec_pretty(&metadata).map_err(io::Error::other)?)?;

    // Publish the dependency list before the executable. If the second rename
    // is interrupted, the old executable is conservatively treated as stale.
    replace_file(&temp_depfile, &context.depfile_path)?;
    replace_file(&temp_sdk_metadata, &context.sdk_metadata_path)?;
    replace_file(&temp_aot, &context.aot_path)?;
    fs::canonicalize(context.aot_path)
}

fn spawn_background_worker_aot(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
    context: &AotContext,
) -> io::Result<bool> {
    let lock_path = context
        .aot_sdk_root
        .parent()
        .ok_or_else(|| io::Error::other("AOT SDK directory has no parent"))?
        .join(".aot-background.lock");
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
        .args(["aot-prewarm", "--root"])
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

fn acquire_background_aot_lock(path: &Path) -> io::Result<bool> {
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

fn aot_cache_key(
    workspace: &Workspace,
    worker_path: &Path,
    sdk_root: &Path,
) -> io::Result<String> {
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

fn aot_sdk_identity(sdk_root: &Path) -> io::Result<(String, String)> {
    let sdk_root = fs::canonicalize(sdk_root)?;
    let version = fs::read(sdk_root.join("version"))?;
    let allowed_experiments = fs::read(
        sdk_root
            .join("lib")
            .join("_internal")
            .join("allowed_experiments.json"),
    )?;
    Ok((
        digest_bytes(&version),
        digest_bytes(&allowed_experiments),
    ))
}

fn build_aot_metadata(
    workspace: &Workspace,
    sdk_root: &Path,
    worker_path: &Path,
    depfile: &Path,
    cache_key: &str,
) -> io::Result<AotMetadata> {
    let dependencies = parse_depfile_dependencies(&fs::read_to_string(depfile)?)
        .ok_or_else(|| io::Error::other("AOT compiler depfile has no dependencies"))?;
    let package_config_path = fs::canonicalize(
        workspace
            .root
            .join(".dart_tool/package_config.json"),
    )?;
    let canonical_sdk_root = fs::canonicalize(sdk_root)?;
    let mut dependency_digests = BTreeMap::new();
    for dependency in dependencies {
        let dependency = fs::canonicalize(dependency)?;
        if dependency == package_config_path
            || dependency
                .strip_prefix(&canonical_sdk_root)
                .is_ok()
        {
            continue;
        }
        let key = workspace.logical_dependency_key(&dependency).ok_or_else(|| {
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
        fs::remove_file(&destination)?;
    } else if destination.exists() {
        return Err(io::Error::other(format!(
            "AOT SDK path is not a symlink: {}",
            destination.display()
        )));
    }

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

fn parse_depfile_dependencies(contents: &str) -> Option<Vec<PathBuf>> {
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

#[cfg(test)]
mod tests {
    use super::{acquire_background_aot_lock, background_aot_lock_is_stale, parse_depfile_dependencies, WorkerArtifact};
    use std::fs::{self, OpenOptions};
    use std::sync::{Arc, Barrier};
    use std::thread;
    use std::path::PathBuf;

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
}
