use crate::builder::{BuilderManifestFile, RustBuildConfig, rust_build_config_from_manifest};
use crate::cli::{FrontendMode, Options};
use crate::worker_kernel::{prewarm_worker_aot, take_background_aot_lock, worker_aot_cache_key};
use crate::workspace::Workspace;
use std::fs;
use std::io;
use std::path::Path;
use std::process::Command;

const MANIFEST_PATH: &str = ".dart_tool/build_runner_accelerator/builder-manifest.json";
const WORKER_ENTRYPOINT_PATH: &str = ".dart_tool/build_runner_accelerator/dynamic_worker.dart";

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
    if manifest.version != 6 || manifest.fingerprint != fingerprint {
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
    let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
    let mut command = Command::new(dart_binary);
    let mut generator_found = false;
    for worker_package in [
        "build_runner_accelerator",
        "build_runner_accelerator_worker",
    ] {
        let Ok(worker_package_root) = workspace.package_root(worker_package) else {
            continue;
        };
        let generator = [
            "tool/generate_builder_manifest.dart",
            "bin/generate_builder_manifest.dart",
        ]
        .into_iter()
        .map(|path| worker_package_root.join(path))
        .find(|path| path.is_file());
        let Some(generator) = generator else {
            continue;
        };
        // Running the package's internal tool directly avoids an implicit
        // pub resolution step. The workspace has already been resolved, so
        // reuse its package config for deterministic/offline manifest
        // generation in CI and installed packages.
        command
            .arg(format!(
                "--packages={}",
                workspace
                    .root
                    .join(".dart_tool/package_config.json")
                    .display()
            ))
            .arg(generator);
        generator_found = true;
        break;
    }
    if !generator_found {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "manifest generator not found in the resolved package roots",
        ));
    }
    let status = command
        .arg("--root")
        .arg(&workspace.root)
        .arg("--manifest")
        .arg(manifest_path)
        .arg("--worker-entrypoint")
        .arg(worker_entrypoint)
        .arg("--fingerprint")
        .arg(fingerprint)
        .current_dir(&workspace.root)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "manifest generator exited with {status}"
        )))
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
    let artifact = prewarm_worker_aot(&workspace.root, dart_binary, &worker)?;
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
