use crate::builder::{rust_build_config_from_manifest, BuilderManifestFile, RustBuildConfig};
use crate::cli::{FrontendMode, Options};
use crate::workspace::Workspace;
use std::fs;
use std::io;
use std::path::Path;
use std::process::Command;

const MANIFEST_PATH: &str = ".dart_tool/fast_build_runner/builder-manifest.json";
const WORKER_ENTRYPOINT_PATH: &str = ".dart_tool/fast_build_runner/dynamic_worker.dart";

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
    let manifest = match read_manifest(&manifest_path, &fingerprint)? {
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
            match read_manifest(&manifest_path, &manifest_fingerprint)? {
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

fn read_manifest(path: &Path, fingerprint: &str) -> io::Result<Option<BuilderManifestFile>> {
    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let manifest = match serde_json::from_str::<BuilderManifestFile>(&contents) {
        Ok(manifest) => manifest,
        Err(_) => return Ok(None),
    };
    if manifest.version != 6
        || manifest.fingerprint != fingerprint
        || !Path::new(&manifest.worker_entrypoint).is_file()
    {
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
    let status = Command::new(dart_binary)
        .args([
            "--suppress-analytics",
            "run",
            "fast_build_runner_worker:generate_builder_manifest",
            "--root",
        ])
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
    let status = Command::new(dart_binary)
        .args([
            "--suppress-analytics",
            "run",
            "build_runner",
            "build",
            "--delete-conflicting-outputs",
        ])
        .current_dir(&workspace.root)
        .status()?;
    if !status.success() {
        return Err(io::Error::other(format!("Dart fallback failed: {status}")));
    }
    println!("Build completed (Dart fallback)");
    Ok(())
}
