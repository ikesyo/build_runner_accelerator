use crate::builder::{BuilderManifestFile, RustBuildConfig, rust_build_config_from_manifest};
use crate::cli::Options;
use crate::worker_kernel::{
    AOT_COMPILE_LOCK_NAME, BACKGROUND_AOT_LOCK_ENV, acquire_background_aot_lock,
    analysis_prewarm_enabled, early_worker_aot_compile, early_worker_aot_enabled,
    manifest_prewarm_enabled, prewarm_worker_aot, start_analysis_prewarm,
    start_manifest_analysis_prewarm, take_background_aot_lock, worker_aot_cache_key,
};
use crate::workspace::Workspace;
use std::fs;
use std::io::{self, Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime};

pub(crate) const STOCK_OUTPUT_POLICY_STATE: &str =
    ".dart_tool/build_runner_accelerator/stock-output-policy-state";

const MANIFEST_PATH: &str = ".dart_tool/build_runner_accelerator/builder-manifest.json";
const WORKER_ENTRYPOINT_PATH: &str = ".dart_tool/build_runner_accelerator/dynamic_worker.dart";
const EARLY_WORKER_MARKER_MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);

pub(crate) struct NativeFrontend {
    pub config: RustBuildConfig,
    pub preflight: Option<crate::build::Preflight>,
}

impl NativeFrontend {
    pub fn new(config: RustBuildConfig) -> Self {
        Self {
            config,
            preflight: None,
        }
    }
}

pub(crate) fn prepare_native_frontend(
    options: &Options,
    workspace: &Workspace,
    state: &crate::graph::GraphState,
) -> io::Result<NativeFrontend> {
    // Detect the state-dependent watch boundary before preparing a manifest.
    let retained_output_state =
        matches!(options.command.as_str(), "build" | "watch") && state.retained_output_state;
    if retained_output_state && options.command == "watch" {
        return unsupported("watch after retained output state is unsupported");
    }

    let manifest = prepare_manifest(options, workspace)?;
    let config = validate_native_manifest(options, workspace, manifest, retained_output_state)?;
    let preflight =
        preflight_native_state(options, workspace, &config, state, retained_output_state)?;
    Ok(NativeFrontend { config, preflight })
}

/// Prepare and validate cache identity without deciding supported state transitions.
fn prepare_manifest(options: &Options, workspace: &Workspace) -> io::Result<BuilderManifestFile> {
    if let Some(name) = options.settings.config_path()?
        && !workspace.root.join(name.clone()).is_file()
    {
        return unsupported(&format!("configuration file not found: {name}"));
    }
    let fingerprint = settings_fingerprint(options, workspace)
        .map_err(|error| contextual_error("cannot read configuration inputs", error))?;
    let manifest_path = workspace.root.join(MANIFEST_PATH);
    let worker_entrypoint = workspace.root.join(WORKER_ENTRYPOINT_PATH);
    let manifest = match read_manifest(&manifest_path, &fingerprint, &worker_entrypoint)? {
        Some(manifest) => manifest,
        None => {
            // The first PackageGraph load can normalize package_config.json.
            // Recompute the fingerprint after generation and regenerate once
            // if that normalization changed the workspace input.
            let mut manifest_fingerprint = fingerprint;
            for _ in 0..3 {
                generate_manifest(
                    options,
                    workspace,
                    &manifest_fingerprint,
                    &manifest_path,
                    &worker_entrypoint,
                )
                .map_err(|error| {
                    contextual_error("dynamic builder manifest generation failed", error)
                })?;
                let refreshed = settings_fingerprint(options, workspace)
                    .map_err(|error| contextual_error("cannot read configuration inputs", error))?;
                if refreshed == manifest_fingerprint {
                    break;
                }
                manifest_fingerprint = refreshed;
            }
            match read_manifest(&manifest_path, &manifest_fingerprint, &worker_entrypoint)? {
                Some(manifest) => manifest,
                None => {
                    return unsupported("dynamic builder manifest was not written");
                }
            }
        }
    };

    Ok(manifest)
}

/// Keep the original I/O error in the source chain as well as the user message.
#[derive(Debug)]
struct FrontendError {
    context: &'static str,
    source: io::Error,
}
impl std::fmt::Display for FrontendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.context, self.source)
    }
}
impl std::error::Error for FrontendError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.source)
    }
}
fn contextual_error(context: &'static str, source: io::Error) -> io::Error {
    io::Error::new(source.kind(), FrontendError { context, source })
}

/// Preparation failures are fatal to watch even when their original I/O kind
/// is recoverable. Keep this policy separate from the diagnostic source chain.
pub(crate) fn is_terminal_frontend_error(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::Unsupported
        || error
            .get_ref()
            .is_some_and(|source| source.is::<FrontendError>())
}

fn validate_native_manifest(
    options: &Options,
    workspace: &Workspace,
    manifest: BuilderManifestFile,
    retained_output_state: bool,
) -> io::Result<RustBuildConfig> {
    match rust_build_config_from_manifest(manifest) {
        Ok(config) => {
            for (name, locked_root) in &options.workspace_output_packages {
                if crate::workspace::canonicalize(workspace.package_root(name)?)? != *locked_root {
                    return unsupported(
                        "workspace package paths changed after locks were acquired; retry",
                    );
                }
            }
            if config.builders.iter().any(|builder| {
                let is_output = if options.settings.workspace {
                    options
                        .workspace_output_packages
                        .contains_key(&builder.package)
                } else {
                    builder.package == workspace.root_package
                };
                builder.is_root != is_output
            }) {
                return unsupported(
                    "manifest output-package markers disagree with the locked build scope",
                );
            }
            if config.builders.iter().any(|builder| {
                !builder.is_root
                    && builder.definition.kind == crate::builder::BuilderKind::Normal
                    && builder.definition.build_to == crate::builder::BuildTo::Source
            }) {
                return unsupported("source builders cannot write into non-output packages");
            }
            workspace.configure_sources(config.asset_sources.as_ref());
            if workspace.includes_build_implementation_sources() {
                return unsupported(
                    "target sources include build implementation directories under .dart_tool; native cannot model stock artifact-tree inputs",
                );
            }
            let settings = &options.settings;
            if settings.workspace {
                if config.builders.iter().any(|builder| {
                    builder.definition.is_optional
                        || builder.definition.adds_to_library
                        || builder
                            .options
                            .get("run_only_if_triggered")
                            .and_then(serde_json::Value::as_bool)
                            == Some(true)
                }) {
                    return unsupported(
                        "--workspace currently supports non-optional builders without shared parts or triggers",
                    );
                }
                if workspace.overlapping_watch_sources()?.is_some() {
                    return unsupported(
                        "--workspace source sets may overlap nested packages; narrow target sources first",
                    );
                }
            }
            if config.builders.iter().any(|builder| {
                builder.definition.adds_to_library
                    && builder
                        .options
                        .get("run_only_if_triggered")
                        .and_then(serde_json::Value::as_bool)
                        == Some(true)
            }) {
                return unsupported(
                    "shared-library trigger-only builders are outside the supported subset",
                );
            }
            let demand_policy = (settings.only_check
                && !config
                    .builders
                    .iter()
                    .any(|builder| builder.definition.adds_to_library))
                || settings.keep_modified_outputs
                || retained_output_state;
            let filters = &settings.build_filters;
            if (demand_policy || !filters.is_empty())
                && config.builders.iter().any(|b| {
                    b.definition.is_optional
                        || b.options
                            .get("run_only_if_triggered")
                            .and_then(serde_json::Value::as_bool)
                            == Some(true)
                        || b.definition.kind == crate::builder::BuilderKind::PostProcess
                        || b.effective_definition()
                            .extensions
                            .iter()
                            .any(|e| e.output_suffixes.is_empty())
                })
            {
                return unsupported(
                    "output policies/build filters with optional, post-process, trigger-only or zero-output builders are outside the supported subset",
                );
            }
            Ok(config)
        }
        Err(error) => unsupported(&format!(
            "dynamic builder manifest is outside the supported subset: {error}"
        )),
    }
}

fn preflight_native_state(
    options: &Options,
    workspace: &Workspace,
    config: &RustBuildConfig,
    state: &crate::graph::GraphState,
    retained_output_state: bool,
) -> io::Result<Option<crate::build::Preflight>> {
    let settings = &options.settings;
    let demand_policy = (settings.only_check
        && !config
            .builders
            .iter()
            .any(|builder| builder.definition.adds_to_library))
        || settings.keep_modified_outputs
        || retained_output_state;
    let filters = &settings.build_filters;
    let mut preflight = None;
    let transition_reason = if demand_policy || !filters.is_empty() {
        crate::build::filtered_transition_reason(
            workspace,
            config,
            demand_policy,
            state,
            &mut preflight,
        )?
    } else if matches!(options.command.as_str(), "build" | "watch") {
        crate::build::dependency_output_conflict_reason(workspace, config, state, &mut preflight)?
    } else {
        None
    };
    if let Some(reason) = transition_reason {
        return unsupported(reason);
    }
    Ok(preflight)
}

/// Settings are runtime inputs to both probing and action graph reuse. File
/// names, absent selected configs, and every override are part of the identity.
fn settings_fingerprint(options: &Options, workspace: &Workspace) -> io::Result<String> {
    // Earlier manifests applied physical-source defaults to action scopes,
    // omitting virtual-primary producers outside dependency source defaults.
    let mut bytes = b"native-settings-v4\0".to_vec();
    bytes.extend_from_slice(workspace.builder_manifest_fingerprint()?.as_bytes());
    bytes.extend_from_slice(
        &serde_json::to_vec(&crate::build_filter::configuration_arguments(
            &options.settings,
        )?)
        .map_err(io::Error::other)?,
    );
    let settings = &options.settings;
    let mut paths = std::collections::BTreeSet::new();
    for entry in fs::read_dir(&workspace.root)? {
        let entry = entry?;
        if entry.path().is_file() && entry.file_name().to_string_lossy().ends_with(".build.yaml") {
            paths.insert(entry.path());
        }
    }
    if let Some(config) = settings.config_path()? {
        paths.insert(workspace.root.join(config));
    }
    for path in paths {
        bytes.extend_from_slice(
            path.strip_prefix(&workspace.root)
                .unwrap_or(&path)
                .to_string_lossy()
                .as_bytes(),
        );
        bytes.push(0);
        match fs::read(path) {
            Ok(content) => {
                bytes.push(1);
                bytes.extend_from_slice(&content);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => bytes.push(0),
            Err(error) => return Err(error),
        }
        bytes.push(0xff);
    }
    Ok(crate::digest::digest_bytes(&bytes))
}

fn read_manifest(
    path: &Path,
    fingerprint: &str,
    expected_worker_entrypoint: &Path,
) -> io::Result<Option<BuilderManifestFile>> {
    let contents = match fs::read(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let mut manifest = match serde_json::from_slice::<BuilderManifestFile>(&contents) {
        Ok(manifest) => manifest,
        Err(_) => return Ok(None),
    };
    if manifest.version != 11 || manifest.fingerprint != fingerprint {
        return Ok(None);
    }
    // Refresh pre-scheduler caches even when pubspec/build.yaml inputs have
    // not changed. Directly decoded legacy manifests remain safely serial.
    if manifest.builders.iter().any(|builder| {
        builder.target_dependencies.is_none() || builder.package_dependencies.is_none()
    }) {
        return Ok(None);
    }
    if !expected_worker_entrypoint.is_file() {
        return Ok(None);
    }
    // The worker is published before the manifest. An interrupted generation
    // or a mixed restored cache must not pair an old plan with a new catalog.
    let Some(expected_digest) = manifest.worker_source_digest.as_deref() else {
        return Ok(None);
    };
    let worker_source = match fs::read(expected_worker_entrypoint) {
        Ok(source) => source,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if crate::digest::digest_bytes(&worker_source) != expected_digest {
        return Ok(None);
    }
    // Rebase a restored cache to this workspace. Never run a worker from a
    // stale absolute manifest path when the local generated worker is missing.
    manifest.worker_entrypoint = expected_worker_entrypoint.to_string_lossy().into_owned();
    if rust_build_config_from_manifest(manifest.clone()).is_err() {
        return Ok(None);
    }
    Ok(Some(manifest))
}

fn generate_manifest(
    options: &Options,
    workspace: &Workspace,
    fingerprint: &str,
    manifest_path: &Path,
    worker_entrypoint: &Path,
) -> io::Result<()> {
    let _wall = crate::wall::Span::new("manifest_generate");
    let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
    let settings_json =
        serde_json::to_string(&options.build_arguments).map_err(io::Error::other)?;
    // Fill the shared analyzer byte store while this window is otherwise
    // CPU-idle on the Rust side: generator kernel compile/load, the early
    // catalog helper, the overlapped worker AOT compile and the factory
    // probe. The handle kills the shards on return — after the overlapped
    // AOT compile and probe have finished — so they never run alongside the
    // workers spawned by the build itself.
    let _manifest_prewarm = if manifest_prewarm_enabled() {
        start_manifest_analysis_prewarm(&workspace.root, dart_binary)
    } else {
        None
    };
    let mut command = Command::new(dart_binary);
    let package_root = workspace.package_root("build_runner_accelerator")?;
    let generator = [
        "tool/generate_builder_manifest.dart",
        "bin/generate_builder_manifest.dart",
    ]
    .into_iter()
    .map(|path| package_root.join(path))
    .find(|path| path.is_file())
    .ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "manifest generator not found in build_runner_accelerator package",
        )
    })?;
    cleanup_stale_worker_readiness_markers(worker_entrypoint);
    // The generator writes the worker entrypoint early (before its factory
    // probe). Remove any stale copy first so its appearance marks the moment
    // the synchronous worker AOT compile can start; the compile then overlaps
    // the probe instead of serializing after it on a cold build. When the
    // removal fails, a lingering stale entrypoint could trigger a compile of
    // the old script, so the early path is disabled entirely.
    let mut early_compile_ready = match fs::remove_file(worker_entrypoint) {
        Ok(()) => true,
        Err(error) if error.kind() == io::ErrorKind::NotFound => true,
        Err(error) => {
            eprintln!("Rust worker entrypoint cleanup failed; disabling early AOT ({error})");
            false
        }
    };
    let mut early_compile = None;
    let mut early_source = None;
    // Readiness belongs to this generator invocation, never a restored cache.
    static NEXT_PROBE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let readiness = if early_compile_ready
        && options.worker.is_none()
        && early_worker_aot_enabled()
        && std::env::var("BUILD_RUNNER_ACCELERATOR_EARLY_CATALOG").as_deref() != Ok("0")
    {
        let path = worker_entrypoint.with_file_name(format!(
            ".early-worker-{}-{}.json",
            std::process::id(),
            NEXT_PROBE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir_all(path.parent().unwrap()).ok();
        fs::write(&path, r#"{"state":"pending"}"#)
            .ok()
            .map(|_| path)
    } else {
        None
    };
    let generation_start = std::time::Instant::now();
    let artifact =
        crate::manifest_generator::resolve(&workspace.root, dart_binary, &generator, || {
            if !early_compile_ready
                || options.worker.is_some()
                || !early_worker_aot_enabled()
                || std::env::var("BUILD_RUNNER_ACCELERATOR_EARLY_CATALOG").as_deref() == Ok("0")
            {
                return;
            }
            let helper = package_root.join("tool/generate_worker_catalog.dart");
            if !helper.is_file() {
                return;
            }
            let result = Command::new(dart_binary)
                .arg(format!(
                    "--packages={}",
                    crate::runner_compatibility::package_config(&workspace.root).display()
                ))
                .arg(&helper)
                .arg(&workspace.root)
                .arg(worker_entrypoint)
                .arg(&settings_json)
                .current_dir(&workspace.root)
                .status();
            match result {
                Ok(status) if status.success() && worker_entrypoint.is_file() => {
                    if let Ok(source) = fs::read(worker_entrypoint) {
                        early_source = Some(source);
                        early_compile = early_worker_aot_compile(
                            workspace,
                            dart_binary,
                            &worker_entrypoint.to_string_lossy(),
                            readiness.as_deref(),
                        );
                    }
                    if std::env::var("BUILD_RUNNER_ACCELERATOR_METRICS").as_deref() == Ok("1") {
                        eprintln!(
                            "Rust manifest early catalog: elapsed_us={} aot_started={}",
                            generation_start.elapsed().as_micros(),
                            early_compile.is_some()
                        );
                    }
                }
                _ => {
                    eprintln!("Rust early catalog unavailable; using full generator");
                    // A helper may have emitted a partial or outdated entrypoint.
                    if let Err(error) = fs::remove_file(worker_entrypoint)
                        && error.kind() != io::ErrorKind::NotFound
                    {
                        early_compile_ready = false;
                        eprintln!(
                            "Rust early catalog cleanup failed; disabling early AOT ({error})"
                        );
                    }
                }
            }
        });
    command
        .arg(format!(
            "--packages={}",
            crate::runner_compatibility::package_config(&workspace.root).display()
        ))
        .arg(artifact);
    command.env_remove("BUILD_RUNNER_ACCELERATOR_MANIFEST_WORKER_AOT");
    if let Some(path) = &readiness
        && early_compile_ready
    {
        command.env("BUILD_RUNNER_ACCELERATOR_MANIFEST_WORKER_AOT", path);
    }
    let child_result = command
        .arg("--root")
        .arg(&workspace.root)
        .arg("--manifest")
        .arg(manifest_path)
        .arg("--worker-entrypoint")
        .arg(worker_entrypoint)
        .arg("--fingerprint")
        .arg(fingerprint)
        .arg("--settings-json")
        .arg(&settings_json)
        .current_dir(&workspace.root)
        .stderr(Stdio::piped())
        .spawn();
    let diagnostics = std::sync::Arc::new(std::sync::Mutex::new(Vec::<u8>::new()));
    let mut stderr_done = None;
    let status = match child_result {
        Err(error) => Err(error),
        Ok(mut child) => {
            if let Some(mut pipe) = child.stderr.take() {
                let tail = std::sync::Arc::clone(&diagnostics);
                let (done, receiver) = std::sync::mpsc::channel();
                stderr_done = Some(receiver);
                std::thread::spawn(move || {
                    let mut buffer = [0; 4096];
                    while let Ok(count) = pipe.read(&mut buffer) {
                        if count == 0 {
                            break;
                        }
                        let _ = io::stderr().write_all(&buffer[..count]);
                        let mut tail = tail.lock().unwrap();
                        tail.extend_from_slice(&buffer[..count]);
                        let excess = tail.len().saturating_sub(32 * 1024);
                        tail.drain(..excess);
                    }
                    let _ = done.send(());
                });
            }
            loop {
                match child.try_wait() {
                    Ok(Some(status)) => break Ok(status),
                    Ok(None) => {
                        if early_compile_ready
                            && early_compile.is_none()
                            && worker_entrypoint.is_file()
                        {
                            early_source = fs::read(worker_entrypoint).ok();
                            early_compile = early_worker_aot_compile(
                                workspace,
                                dart_binary,
                                &worker_entrypoint.to_string_lossy(),
                                readiness.as_deref(),
                            );
                        }
                        std::thread::sleep(Duration::from_millis(50));
                    }
                    Err(error) => break Err(error),
                }
            }
        }
    };
    // A descendant may retain stderr after the generator exits. Keep draining
    // without allowing EOF to block frontend preparation indefinitely.
    if let Some(done) = stderr_done {
        let _ = done.recv_timeout(Duration::from_secs(1));
    }
    // Always join before returning: `prepare_worker_aot` uses pid-named temp
    // files, so it must not overlap a later invocation in this process — even
    // when polling the generator itself failed.
    if let Some(handle) = early_compile {
        match handle.join() {
            Ok(Ok(artifact)) => {
                if early_source
                    .as_ref()
                    .is_some_and(|source| fs::read(worker_entrypoint).ok().as_ref() != Some(source))
                {
                    let _ = fs::remove_file(artifact);
                    eprintln!(
                        "Rust early catalog differed from final worker; discarding early AOT"
                    );
                }
            }
            Ok(Err(error)) => {
                eprintln!("Rust worker early AOT compile failed; will retry ({error})")
            }
            Err(_) => eprintln!("Rust worker early AOT compile panicked; will retry"),
        }
    }
    if let Some(path) = readiness {
        let _ = fs::remove_file(path);
    }
    let status = status?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "manifest generator exited with {status}\n{}",
            String::from_utf8_lossy(&diagnostics.lock().unwrap())
        )))
    }
}

fn cleanup_stale_worker_readiness_markers(worker_entrypoint: &Path) {
    let Some(directory) = worker_entrypoint.parent() else {
        return;
    };
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with(".early-worker-")
            || !(name.ends_with(".json") || name.ends_with(".tmp"))
            || !entry.file_type().is_ok_and(|kind| kind.is_file())
        {
            continue;
        }
        let stale = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .ok()
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age >= EARLY_WORKER_MARKER_MAX_AGE);
        if stale {
            // Keep recent markers: another build process may still be waiting
            // on its AOT compile. Treat week-old markers as abandoned.
            let _ = fs::remove_file(entry.path());
        }
    }
}

pub(crate) fn worker_executable(options: &Options, config: &RustBuildConfig) -> io::Result<String> {
    options
        .worker
        .clone()
        .or_else(|| {
            config
                .worker_entrypoint
                .as_ref()
                .map(|path| path.to_string_lossy().into_owned())
        })
        .ok_or_else(|| io::Error::other("builder manifest has no worker entrypoint"))
}

pub(crate) fn run_aot_cache_key(options: &Options) -> io::Result<()> {
    let workspace = Workspace::load(options.root.clone())?;
    let build_config =
        prepare_native_frontend(options, &workspace, &crate::graph::GraphState::default())?;
    let build_config = build_config.config;
    let worker = worker_executable(options, &build_config)?;
    let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
    println!(
        "{}",
        worker_aot_cache_key(&workspace, dart_binary, &worker)?
    );
    Ok(())
}

pub(crate) fn run_aot_prewarm(options: &Options) -> io::Result<()> {
    if options.background {
        return run_prewarm_detached(options);
    }
    let _background_lock = take_background_aot_lock();
    let workspace = load_prewarm_workspace(options)?;
    let build_config =
        prepare_native_frontend(options, &workspace, &crate::graph::GraphState::default())?;
    let build_config = build_config.config;
    let worker = worker_executable(options, &build_config)?;
    let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
    // Warm the shared analyzer byte store alongside the worker AOT compile:
    // the JIT prewarm overlaps the compile and continues to completion.
    // Opt out with BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM=0 for serial
    // foreground/CI runs where the sweep cost has nothing to hide behind.
    let analysis_prewarm = analysis_prewarm_enabled()
        .then(|| start_analysis_prewarm(&workspace.root, dart_binary))
        .flatten();
    let artifact = prewarm_worker_aot(&workspace, dart_binary, &worker)?;
    if let Some(analysis_prewarm) = analysis_prewarm {
        analysis_prewarm.wait_for_children();
    }
    let cache_key = worker_aot_cache_key(&workspace, dart_binary, &worker)?;
    println!("AOT prewarm ready: {}", artifact.display());
    println!("AOT cache key: {cache_key}");
    Ok(())
}

fn load_prewarm_workspace(options: &Options) -> io::Result<Workspace> {
    Workspace::load(options.root.clone()).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("cannot load workspace (run dart pub get first): {error}"),
        )
    })
}

/// `prewarm --background`: spawn a detached copy of this binary running the
/// foreground pipeline and return immediately. The workspace compile lock is
/// taken here and passed to the child through the environment, which both
/// makes a second `--background` invocation a no-op and lets concurrent
/// builds wait for the published artifact instead of recompiling.
fn run_prewarm_detached(options: &Options) -> io::Result<()> {
    // Fail fast on an unresolved workspace before touching the lock.
    // The canonical workspace root must back every path the child recomputes:
    // the compile-lock comparison in `prepare_worker_aot` is textual.
    let workspace = load_prewarm_workspace(options)?;
    let generated_dir = workspace
        .root
        .join(".dart_tool")
        .join("build_runner_accelerator");
    fs::create_dir_all(&generated_dir)?;
    let lock_path = generated_dir.join(AOT_COMPILE_LOCK_NAME);
    if !acquire_background_aot_lock(&lock_path)? {
        eprintln!("Rust AOT prewarm is already running; nothing to do");
        return Ok(());
    }
    let result = spawn_detached_prewarm(options, &workspace, &generated_dir, &lock_path);
    if result.is_err() {
        let _ = fs::remove_file(&lock_path);
    }
    result
}

fn spawn_detached_prewarm(
    options: &Options,
    workspace: &Workspace,
    generated_dir: &Path,
    lock_path: &Path,
) -> io::Result<()> {
    use std::fs::OpenOptions;
    let log_path = generated_dir.join("prewarm.log");
    let log_stdout = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&log_path)?;
    let log_stderr = log_stdout.try_clone()?;
    let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
    let mut command = detached_prewarm_command()?;
    command.env_remove(crate::process::SUPERVISION_CONTEXT);
    command
        .args(["prewarm", "--root"])
        .arg(&workspace.root)
        .args(["--dart"])
        .arg(dart_binary)
        .current_dir(&workspace.root)
        .env(BACKGROUND_AOT_LOCK_ENV, lock_path)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log_stdout))
        .stderr(Stdio::from(log_stderr));
    command.args(&options.build_arguments);
    if let Some(worker) = &options.worker {
        command.args(["--worker"]).arg(worker);
    }
    let child = spawn_detached_prewarm_child(&mut command)?;
    eprintln!(
        "Rust AOT prewarm running in background (pid {}); log: {}",
        child.id(),
        log_path.display()
    );
    // The child is reparented when this process exits, so it neither holds
    // the terminal nor needs a reaper here; it removes the lock on exit.
    Ok(())
}

/// Build the detached `prewarm` invocation for this platform: a new process
/// group so the child survives the terminal, and lowered scheduling priority
/// so setup-time work stays out of the developer's way.
#[cfg(unix)]
fn detached_prewarm_command() -> io::Result<Command> {
    use std::os::unix::process::CommandExt;
    unsafe extern "C" {
        fn nice(increment: i32) -> i32;
        fn setsid() -> i32;
    }
    let mut command = Command::new(std::env::current_exe()?);
    // SAFETY: pre_exec runs after fork, before exec; these libc calls do not
    // allocate or acquire Rust locks. setsid detaches the controlling terminal.
    unsafe {
        command.pre_exec(|| {
            if setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            nice(19);
            Ok(())
        });
    }
    Ok(command)
}

#[cfg(windows)]
fn detached_prewarm_command() -> io::Result<Command> {
    Ok(Command::new(std::env::current_exe()?))
}

/// Preserve detachment and priority when an enclosing Windows job disallows
/// breakaway. The supervisor clears kill-on-close after successful prewarm setup.
#[cfg(windows)]
fn spawn_detached_prewarm_child(command: &mut Command) -> io::Result<std::process::Child> {
    use std::os::windows::process::CommandExt;
    const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const BELOW_NORMAL_PRIORITY_CLASS: u32 = 0x0000_4000;
    let detached_flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | BELOW_NORMAL_PRIORITY_CLASS;
    spawn_with_breakaway_retry(|breakaway| {
        command.creation_flags(
            detached_flags
                | if breakaway {
                    CREATE_BREAKAWAY_FROM_JOB
                } else {
                    0
                },
        );
        command.spawn()
    })
}

#[cfg(not(windows))]
fn spawn_detached_prewarm_child(command: &mut Command) -> io::Result<std::process::Child> {
    command.spawn()
}

/// Retry only Windows ERROR_ACCESS_DENIED; other spawn errors keep their cause.
#[cfg(any(windows, test))]
fn spawn_with_breakaway_retry<T>(mut spawn: impl FnMut(bool) -> io::Result<T>) -> io::Result<T> {
    match spawn(true) {
        Err(error) if error.raw_os_error() == Some(5) => spawn(false),
        result => result,
    }
}

#[cfg(not(any(unix, windows)))]
fn detached_prewarm_command() -> io::Result<Command> {
    Ok(Command::new(std::env::current_exe()?))
}

pub(crate) fn unsupported<T>(reason: &str) -> io::Result<T> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        format!(
            "Native frontend cannot handle this request: {reason}. Run dart run build_runner directly if needed."
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::{EARLY_WORKER_MARKER_MAX_AGE, cleanup_stale_worker_readiness_markers};
    use std::fs::{self, File, FileTimes};
    use std::time::{Duration, SystemTime};

    #[test]
    fn preparation_context_preserves_io_kind_and_source() {
        let os_code = if cfg!(windows) { 5 } else { 13 };
        let error = super::contextual_error("prepare", std::io::Error::from_raw_os_error(os_code));
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
        assert!(super::is_terminal_frontend_error(&error));
        assert!(!super::is_terminal_frontend_error(&std::io::Error::other(
            "builder failed"
        )));
        assert!(super::is_terminal_frontend_error(&std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "unsupported transition"
        )));
        assert!(error.to_string().contains("prepare"));
        let context = error.get_ref().unwrap();
        let source = context
            .source()
            .unwrap()
            .downcast_ref::<std::io::Error>()
            .unwrap();
        assert_eq!(source.raw_os_error(), Some(os_code));
    }

    #[test]
    fn breakaway_retry_is_scoped_to_access_denied() {
        for error in [None, Some(5), Some(2), Some(87)] {
            let mut attempts = Vec::new();
            let result = super::spawn_with_breakaway_retry(|breakaway| {
                attempts.push(breakaway);
                if breakaway && let Some(code) = error {
                    return Err(std::io::Error::from_raw_os_error(code));
                }
                Ok(23)
            });
            if error == Some(5) {
                assert_eq!(attempts, [true, false]);
                assert_eq!(result.unwrap(), 23);
            } else {
                assert_eq!(attempts, [true]);
                assert_eq!(result.as_ref().err().and_then(|e| e.raw_os_error()), error);
            }
        }
    }

    #[test]
    fn breakaway_retry_propagates_the_second_spawn_error() {
        let mut attempts = Vec::new();
        let result = super::spawn_with_breakaway_retry::<()>(|breakaway| {
            attempts.push(breakaway);
            Err(std::io::Error::from_raw_os_error(if breakaway {
                5
            } else {
                2
            }))
        });
        assert_eq!(attempts, [true, false]);
        assert_eq!(result.unwrap_err().raw_os_error(), Some(2));
    }

    #[test]
    fn obsolete_or_incomplete_manifest_and_missing_local_worker_are_cache_misses() {
        let root = std::env::temp_dir().join(format!(
            "accelerator-manifest-contract-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("manifest.json");
        let local = root.join("local.dart");
        let stale = root.join("stale.dart");
        fs::write(&local, "local worker").unwrap();
        fs::write(&stale, "stale worker").unwrap();
        let mut valid = serde_json::json!({
            "version": 11, "asset_sources": {}, "fingerprint": "same", "trigger_digest": "stock", "worker_entrypoint": stale,
            "worker_source_digest": crate::digest::digest_bytes(b"local worker"),
            "definitions": [{"id": "app:copy", "kind": "normal", "extensions": [{"input_suffix": ".txt", "input_match": "suffix", "input_anchored": false, "output_suffixes": [".out"]}], "build_to": "source", "phase": 0}],
            "builders": [{"id": "app:copy", "kind": "normal", "build_to": "source", "phase": 0, "target": "app:app", "package": "app", "is_root": true, "generate_for": ["**"]}]
        });
        for field in ["builders", "definitions"] {
            for entry in valid[field].as_array_mut().unwrap() {
                let object = entry.as_object_mut().unwrap();
                for name in [
                    "required_input_suffixes",
                    "excluded_input_suffixes",
                    "generate_for",
                    "generate_for_exclude",
                    "target_sources",
                    "target_sources_exclude",
                    "triggers",
                ] {
                    object.entry(name).or_insert_with(|| serde_json::json!([]));
                }
                object.insert("options".into(), serde_json::json!({}));
                object.insert("is_optional".into(), serde_json::json!(false));
                object.insert("output_is_optional".into(), serde_json::json!(false));
            }
        }
        valid["builders"][0]["target_order"] = serde_json::json!(0);
        valid["builders"][0]["target_dependencies"] = serde_json::json!([]);
        valid["builders"][0]["package_dependencies"] = serde_json::json!([]);
        fs::write(&path, valid.to_string()).unwrap();
        let hit = super::read_manifest(&path, "same", &local)
            .unwrap()
            .unwrap();
        assert_eq!(hit.worker_entrypoint, local.to_string_lossy());
        fs::write(&local, "a different catalog").unwrap();
        assert!(
            super::read_manifest(&path, "same", &local)
                .unwrap()
                .is_none()
        );
        fs::write(&local, "local worker").unwrap();
        let mut unbound = valid.clone();
        unbound
            .as_object_mut()
            .unwrap()
            .remove("worker_source_digest");
        fs::write(&path, unbound.to_string()).unwrap();
        assert!(
            super::read_manifest(&path, "same", &local)
                .unwrap()
                .is_none()
        );
        let mut empty = valid.clone();
        empty["builders"] = serde_json::json!([]);
        empty["definitions"] = serde_json::json!([]);
        fs::write(&path, empty.to_string()).unwrap();
        let hit = super::read_manifest(&path, "same", &local)
            .unwrap()
            .unwrap();
        assert!(hit.builders.is_empty());
        assert!(hit.definitions.is_empty());
        let config = crate::builder::rust_build_config_from_manifest(hit).unwrap();
        assert!(config.builders.is_empty());
        let mut dangling = valid.clone();
        dangling["definitions"] = serde_json::json!([]);
        fs::write(&path, dangling.to_string()).unwrap();
        assert!(
            super::read_manifest(&path, "same", &local)
                .unwrap()
                .is_none()
        );
        fs::write(&path, [0xff, 0xfe]).unwrap();
        assert!(
            super::read_manifest(&path, "same", &local)
                .unwrap()
                .is_none()
        );
        for (field, value) in [("kind", "post_process"), ("build_to", "cache")] {
            let mut mismatch = valid.clone();
            mismatch["builders"][0][field] = serde_json::json!(value);
            let decoded = serde_json::from_value(mismatch.clone()).unwrap();
            let error = crate::builder::rust_build_config_from_manifest(decoded).unwrap_err();
            assert!(error.to_string().contains("disagrees with definition"));
            fs::write(&path, mismatch.to_string()).unwrap();
            assert!(
                super::read_manifest(&path, "same", &local)
                    .unwrap()
                    .is_none()
            );
        }
        for field in [
            "is_root",
            "kind",
            "options",
            "target_order",
            "target_dependencies",
            "package_dependencies",
            "target_sources",
            "generate_for_exclude",
            "triggers",
        ] {
            let mut missing = valid.clone();
            missing["builders"][0]
                .as_object_mut()
                .unwrap()
                .remove(field);
            fs::write(&path, missing.to_string()).unwrap();
            assert!(
                super::read_manifest(&path, "same", &local)
                    .unwrap()
                    .is_none()
            );
        }
        let mut old = valid.clone();
        old["version"] = serde_json::json!(8);
        fs::write(&path, old.to_string()).unwrap();
        assert!(
            super::read_manifest(&path, "same", &local)
                .unwrap()
                .is_none()
        );
        fs::write(&path, valid.to_string()).unwrap();
        fs::remove_file(&local).unwrap();
        assert!(
            super::read_manifest(&path, "same", &local)
                .unwrap()
                .is_none()
        );
        assert!(stale.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cleanup_removes_only_old_readiness_files() {
        let root = std::env::temp_dir().join(format!(
            "early-worker-readiness-cleanup-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let directory = root.join(".dart_tool/build_runner_accelerator");
        fs::create_dir_all(&directory).unwrap();
        let worker = directory.join("dynamic_worker.dart");
        let stale_json = directory.join(".early-worker-old.json");
        let stale_temp = directory.join(".early-worker-old.tmp");
        let recent = directory.join(".early-worker-active.json");
        let unrelated = directory.join(".early-worker-not-a-marker.txt");
        let marker_directory = directory.join(".early-worker-directory.json");
        for path in [&stale_json, &stale_temp, &recent, &unrelated] {
            File::create(path).unwrap();
        }
        fs::create_dir(&marker_directory).unwrap();
        let old_time = SystemTime::now() - EARLY_WORKER_MARKER_MAX_AGE - Duration::from_secs(1);
        for path in [&stale_json, &stale_temp] {
            File::options()
                .write(true)
                .open(path)
                .unwrap()
                .set_times(FileTimes::new().set_modified(old_time))
                .unwrap();
        }

        cleanup_stale_worker_readiness_markers(&worker);

        assert!(!stale_json.exists());
        assert!(!stale_temp.exists());
        assert!(recent.exists());
        assert!(unrelated.exists());
        assert!(marker_directory.is_dir());
        fs::remove_dir_all(root).unwrap();
    }
}
