use crate::builder::{BuilderManifestFile, RustBuildConfig, rust_build_config_from_manifest};
use crate::cli::{FrontendMode, Options};
use crate::worker_kernel::{
    early_worker_aot_compile, early_worker_aot_enabled, manifest_prewarm_enabled,
    prewarm_worker_aot, start_analysis_prewarm, start_manifest_analysis_prewarm,
    take_background_aot_lock, worker_aot_cache_key,
};
use crate::workspace::Workspace;
use std::fs;
use std::io;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, SystemTime};

const MANIFEST_PATH: &str = ".dart_tool/build_runner_accelerator/builder-manifest.json";
const WORKER_ENTRYPOINT_PATH: &str = ".dart_tool/build_runner_accelerator/dynamic_worker.dart";
const EARLY_WORKER_MARKER_MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);

pub(crate) fn select_frontend(
    options: &Options,
    workspace: &Workspace,
) -> io::Result<Option<RustBuildConfig>> {
    if options.mode == FrontendMode::Dart {
        return Ok(None);
    }

    let fingerprint = workspace.builder_manifest_fingerprint()?;
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
                if let Err(error) = generate_manifest(
                    options,
                    workspace,
                    &manifest_fingerprint,
                    &manifest_path,
                    &worker_entrypoint,
                ) {
                    return select_dart_fallback(
                        options,
                        &format!("dynamic builder manifest generation failed: {error}"),
                    );
                }
                let refreshed = workspace.builder_manifest_fingerprint()?;
                if refreshed == manifest_fingerprint {
                    break;
                }
                manifest_fingerprint = refreshed;
            }
            match read_manifest(&manifest_path, &manifest_fingerprint, &worker_entrypoint)? {
                Some(manifest) => manifest,
                None => {
                    return select_dart_fallback(
                        options,
                        "dynamic builder manifest was not written",
                    );
                }
            }
        }
    };

    if manifest.builders.is_empty() {
        return select_dart_fallback(options, "no builders are configured in the target graph");
    }

    match rust_build_config_from_manifest(manifest) {
        Ok(config) => Ok(Some(config)),
        Err(error) => select_dart_fallback(
            options,
            &format!("dynamic builder manifest is outside the supported subset: {error}"),
        ),
    }
}

fn read_manifest(
    path: &Path,
    fingerprint: &str,
    expected_worker_entrypoint: &Path,
) -> io::Result<Option<BuilderManifestFile>> {
    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let mut manifest = match serde_json::from_str::<BuilderManifestFile>(&contents) {
        Ok(manifest) => manifest,
        Err(_) => return Ok(None),
    };
    if manifest.version != 8 || manifest.fingerprint != fingerprint {
        return Ok(None);
    }
    let manifest_worker_exists = Path::new(&manifest.worker_entrypoint).is_file();
    if expected_worker_entrypoint.is_file() {
        // The generated manifest historically stored an absolute path. Rebase
        // it to the current workspace so the manifest and AOT cache can move
        // between CI runners/workspaces together.
        manifest.worker_entrypoint = expected_worker_entrypoint.to_string_lossy().into_owned();
    } else if !manifest_worker_exists {
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
                    workspace
                        .root
                        .join(".dart_tool/package_config.json")
                        .display()
                ))
                .arg(&helper)
                .arg(&workspace.root)
                .arg(worker_entrypoint)
                .current_dir(&workspace.root)
                .status();
            match result {
                Ok(status) if status.success() && worker_entrypoint.is_file() => {
                    if let Ok(source) = fs::read(worker_entrypoint) {
                        early_source = Some(source);
                        early_compile = early_worker_aot_compile(
                            &workspace.root,
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
                    if let Err(error) = fs::remove_file(worker_entrypoint) {
                        if error.kind() != io::ErrorKind::NotFound {
                            early_compile_ready = false;
                            eprintln!(
                                "Rust early catalog cleanup failed; disabling early AOT ({error})"
                            );
                        }
                    }
                }
            }
        });
    command
        .arg(format!(
            "--packages={}",
            workspace
                .root
                .join(".dart_tool/package_config.json")
                .display()
        ))
        .arg(artifact);
    command.env_remove("BUILD_RUNNER_ACCELERATOR_MANIFEST_WORKER_AOT");
    if let Some(path) = &readiness {
        if early_compile_ready {
            command.env("BUILD_RUNNER_ACCELERATOR_MANIFEST_WORKER_AOT", path);
        }
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
        .current_dir(&workspace.root)
        .spawn();
    let status = match child_result {
        Err(error) => Err(error),
        Ok(mut child) => loop {
            match child.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Ok(None) => {
                    if early_compile_ready && early_compile.is_none() && worker_entrypoint.is_file()
                    {
                        early_source = fs::read(worker_entrypoint).ok();
                        early_compile = early_worker_aot_compile(
                            &workspace.root,
                            dart_binary,
                            &worker_entrypoint.to_string_lossy(),
                            readiness.as_deref(),
                        );
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(error) => break Err(error),
            }
        },
    };
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
            "manifest generator exited with {status}"
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
    let build_config = select_frontend(options, &workspace)?.ok_or_else(|| {
        io::Error::other("AOT cache key requires a Rust-compatible builder manifest")
    })?;
    let worker = worker_executable(options, &build_config)?;
    let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
    println!(
        "{}",
        worker_aot_cache_key(&workspace.root, dart_binary, &worker)?
    );
    Ok(())
}

pub(crate) fn run_aot_prewarm(options: &Options) -> io::Result<()> {
    let _background_lock = take_background_aot_lock();
    let workspace = Workspace::load(options.root.clone())?;
    let build_config = select_frontend(options, &workspace)?.ok_or_else(|| {
        io::Error::other("AOT prewarm requires a Rust-compatible builder manifest")
    })?;
    let worker = worker_executable(options, &build_config)?;
    let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
    // Warm the shared analyzer byte store alongside the worker AOT compile:
    // the JIT prewarm overlaps the compile and continues to completion.
    let analysis_prewarm = start_analysis_prewarm(&workspace.root, dart_binary);
    let artifact = prewarm_worker_aot(&workspace.root, dart_binary, &worker)?;
    if let Some(analysis_prewarm) = analysis_prewarm {
        analysis_prewarm.wait_for_children();
    }
    let cache_key = worker_aot_cache_key(&workspace.root, dart_binary, &worker)?;
    println!("AOT prewarm ready: {}", artifact.display());
    println!("AOT cache key: {cache_key}");
    Ok(())
}

fn select_dart_fallback(options: &Options, reason: &str) -> io::Result<Option<RustBuildConfig>> {
    if options.mode == FrontendMode::Rust {
        return Err(io::Error::other(format!(
            "Rust frontend cannot handle this package: {reason}; use --mode dart"
        )));
    }
    eprintln!("Rust frontend unsupported ({reason}); using Dart fallback");
    Ok(None)
}

pub(crate) fn run_dart_fallback(options: &Options, workspace: &Workspace) -> io::Result<()> {
    let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
    let mut command = Command::new(dart_binary);
    command.args(["--suppress-analytics", "run", "build_runner"]);
    command.arg(&options.command);
    if options.command == "build" {
        command.arg("--delete-conflicting-outputs");
    }
    let status = command.current_dir(&workspace.root).status()?;
    if !status.success() {
        return Err(io::Error::other(format!("Dart fallback failed: {status}")));
    }
    println!("Build completed (Dart fallback)");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{cleanup_stale_worker_readiness_markers, EARLY_WORKER_MARKER_MAX_AGE};
    use std::fs::{self, File, FileTimes};
    use std::time::{Duration, SystemTime};

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
