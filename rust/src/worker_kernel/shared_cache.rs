use super::compile::{AotContext, remove_if_present, replace_file, temporary_sibling};
use crate::digest::digest_bytes;
use crate::workspace::{Workspace, canonicalize};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub(super) const AOT_METADATA_VERSION: u32 = 3;
const AOT_CACHE_KEY_VERSION: &str = "v2";
pub(super) const KERNEL_STAMP_VERSION: u32 = 1;

#[derive(Debug, Deserialize, Serialize)]
pub(super) struct AotMetadata {
    pub(super) format: u32,
    pub(super) cache_key: String,
    pub(super) sdk_version: String,
    pub(super) allowed_experiments: String,
    pub(super) package_config: String,
    pub(super) worker: String,
    pub(super) executable: String,
    pub(super) dependencies: BTreeMap<String, String>,
}

/// Stamp published alongside a cached worker kernel. Reuse requires the
/// same evidence the AOT metadata checks: the effective package
/// configuration, the identity of the SDK that compiled the kernel, a
/// digest of the kernel bytes themselves, and the content digest of
/// every depfile dependency outside the SDK and the package
/// configuration itself (both covered by the first two).
#[derive(Debug, Deserialize, Serialize)]
pub(super) struct KernelStamp {
    pub(super) format: u32,
    pub(super) config_key: String,
    pub(super) sdk_version: String,
    pub(super) allowed_experiments: String,
    pub(super) kernel_digest: String,
    pub(super) dependencies: BTreeMap<String, String>,
}

/// Machine-wide cache root shared by all workspaces, mirroring the Dart
/// `FrontendBinaryResolver.cacheDirectory` contract:
/// `BUILD_RUNNER_ACCELERATOR_CACHE` wins, then the platform cache directory.
/// A relative override resolves against the workspace root so the Rust
/// frontend and its workers agree even when the launcher runs elsewhere.
pub(crate) fn shared_cache_root(workspace_root: &Path) -> Option<PathBuf> {
    if let Ok(configured) = env::var("BUILD_RUNNER_ACCELERATOR_CACHE")
        && !configured.is_empty()
    {
        let path = PathBuf::from(configured);
        return Some(if path.is_absolute() {
            path
        } else {
            workspace_root.join(path)
        });
    }
    if cfg!(target_os = "windows") {
        for variable in ["LOCALAPPDATA", "USERPROFILE"] {
            if let Ok(value) = env::var(variable)
                && !value.is_empty()
            {
                let root = if variable == "USERPROFILE" {
                    PathBuf::from(value).join("AppData").join("Local")
                } else {
                    PathBuf::from(value)
                };
                return Some(root.join("build_runner_accelerator"));
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
    if let Ok(xdg) = env::var("XDG_CACHE_HOME")
        && !xdg.is_empty()
    {
        return Some(PathBuf::from(xdg).join("build_runner_accelerator"));
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
pub(super) fn restore_shared_aot(context: &AotContext) -> io::Result<Option<PathBuf>> {
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
    Ok(Some(canonicalize(&context.aot_path)?))
}

/// Publish the freshly compiled artifact so other checkouts and workspaces
/// with the same cache key skip the synchronous compile. The SDK metadata —
/// the file restore validation depends on — is written last, so a slot
/// interrupted mid-publish stays invalid. Best-effort: any failure leaves
/// the shared slot untouched.
pub(super) fn publish_shared_aot(context: &AotContext) {
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

#[cfg(test)]
pub(crate) fn aot_cache_key(
    workspace: &Workspace,
    worker_path: &Path,
    sdk_root: &Path,
) -> io::Result<String> {
    aot_cache_key_with_worker_digest(workspace, &digest_file(worker_path)?, sdk_root)
}

pub(super) fn aot_cache_key_with_worker_digest(
    workspace: &Workspace,
    worker_digest: &str,
    sdk_root: &Path,
) -> io::Result<String> {
    let (sdk_version, allowed_experiments) = aot_sdk_identity(sdk_root)?;
    // The manifest fingerprint includes the package-config identity and
    // normalized lockfile contents, propagating read errors. Do not append
    // those identities again. The changed key shape invalidates old AOT slots.
    let manifest = workspace.builder_manifest_fingerprint()?;
    Ok(format!(
        "build-runner-accelerator-aot-{AOT_CACHE_KEY_VERSION}-{}-{}-sdk{}-allowed{}-manifest{}-worker{}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        sdk_version,
        allowed_experiments,
        manifest,
        worker_digest,
    ))
}

pub(crate) fn aot_sdk_identity(sdk_root: &Path) -> io::Result<(String, String)> {
    let sdk_root = canonicalize(sdk_root)?;
    let version = fs::read(sdk_root.join("version"))?;
    let allowed_experiments = fs::read(
        sdk_root
            .join("lib")
            .join("_internal")
            .join("allowed_experiments.json"),
    )?;
    Ok((digest_bytes(&version), digest_bytes(&allowed_experiments)))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn build_aot_metadata(
    workspace: &Workspace,
    sdk_root: &Path,
    worker_path: &Path,
    compiled_worker_path: &Path,
    compiler_config: &Path,
    depfile: &Path,
    executable_path: &Path,
    cache_key: &str,
) -> io::Result<AotMetadata> {
    let dependencies = parse_depfile_dependencies(&fs::read_to_string(depfile)?)
        .ok_or_else(|| io::Error::other("AOT compiler depfile has no dependencies"))?;
    let package_config_path = canonicalize(compiler_config)?;
    let canonical_sdk_root = canonicalize(sdk_root)?;
    let compiled_worker = canonicalize(compiled_worker_path)?;
    let mut dependency_digests = BTreeMap::new();
    for dependency in dependencies {
        let dependency = canonicalize(dependency)?;
        if dependency == package_config_path || dependency.strip_prefix(&canonical_sdk_root).is_ok()
        {
            continue;
        }
        // The compiler read a snapshot of the worker source; record
        // that entry under the real entrypoint's key, with the
        // digest of the bytes actually compiled.
        let (key_path, digest_path) = if dependency == compiled_worker {
            (worker_path, compiled_worker_path)
        } else {
            (dependency.as_path(), dependency.as_path())
        };
        let key = workspace.logical_dependency_key(key_path).ok_or_else(|| {
            io::Error::other(format!(
                "AOT dependency is outside the workspace/package graph: {}",
                dependency.display()
            ))
        })?;
        dependency_digests.insert(key, digest_file(digest_path)?);
    }
    let (sdk_version, allowed_experiments) = aot_sdk_identity(sdk_root)?;
    let metadata = AotMetadata {
        format: AOT_METADATA_VERSION,
        cache_key: cache_key.to_owned(),
        sdk_version,
        allowed_experiments,
        package_config: workspace.package_config_identity().to_owned(),
        worker: digest_file(compiled_worker_path)?,
        executable: digest_file(executable_path)?,
        dependencies: dependency_digests,
    };
    // Early/background compilation can precede the build's graph-key read.
    // Reject changed resolution before publishing an executable under this key.
    workspace.read_package_config()?;
    Ok(metadata)
}

/// Validate portable AOT metadata against current identities and file digests.
/// Local receipts accelerate content checks without changing expected digests.
pub(super) fn aot_metadata_is_current(
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
    let mut digests = crate::validated_digest::Cache::load(&workspace.root);
    if !digests.matches(worker_path, &metadata.worker) {
        return false;
    }
    // Bind metadata to the exact executable, including staged restores. On
    // Unix, matching change stamps may reuse a digest from
    // a previous full validation; edits/truncation still force byte validation.
    if !digests.matches(artifact, &metadata.executable) {
        return false;
    }
    let current = metadata.dependencies.iter().all(|(key, expected)| {
        workspace
            .resolve_logical_dependency(key)
            .is_some_and(|path| digests.matches(&path, expected))
    });
    if current {
        digests.save(&workspace.root);
    }
    current
}

pub(super) fn digest_file(path: &Path) -> io::Result<String> {
    Ok(digest_bytes(&fs::read(path)?))
}

pub(super) fn kernel_package_config_key(path: &Path) -> io::Result<String> {
    // Relative package URIs are resolved against the path passed to Dart.
    let mut inputs = fs::read(path)?;
    inputs.push(0);
    inputs.extend_from_slice(path.as_os_str().as_encoded_bytes());
    Ok(digest_bytes(&inputs))
}

pub(super) fn build_kernel_stamp(
    root: &Path,
    sdk_root: &Path,
    kernel: &Path,
    depfile: &Path,
    config_key: &str,
    compile_started: std::time::SystemTime,
) -> io::Result<KernelStamp> {
    let (sdk_version, allowed_experiments) = aot_sdk_identity(sdk_root)?;
    let canonical_sdk_root = canonicalize(sdk_root)?;
    let package_config = canonicalize(crate::runner_compatibility::package_config(root)?)?;
    let dependencies = parse_depfile_dependencies(&fs::read_to_string(depfile)?)
        .ok_or_else(|| io::Error::other("kernel compiler depfile has no dependencies"))?;
    let mut digests = BTreeMap::new();
    for dependency in dependencies {
        let dependency = canonicalize(dependency)?;
        if dependency == package_config || dependency.strip_prefix(&canonical_sdk_root).is_ok() {
            continue;
        }
        // The digests are read after compilation; they only describe the
        // bytes Dart consumed if the input did not change while the
        // compiler ran. Reject the result otherwise and let the caller
        // fall back (the next build retries on settled inputs).
        let modified = fs::metadata(&dependency).and_then(|metadata| metadata.modified())?;
        if modified > compile_started {
            return Err(io::Error::other(format!(
                "kernel input changed during compilation: {}",
                dependency.display()
            )));
        }
        digests.insert(
            dependency.to_string_lossy().into_owned(),
            digest_file(&dependency)?,
        );
    }
    Ok(KernelStamp {
        format: KERNEL_STAMP_VERSION,
        config_key: config_key.to_owned(),
        sdk_version,
        allowed_experiments,
        kernel_digest: digest_file(kernel)?,
        dependencies: digests,
    })
}

pub(super) fn read_kernel_stamp(kernel: &Path) -> Option<KernelStamp> {
    // Missing or unreadable evidence invalidates this disposable cache.
    let contents = fs::read_to_string(kernel.with_extension("dill.config")).ok()?;
    let stamp = serde_json::from_str::<KernelStamp>(&contents).ok()?;
    (stamp.format == KERNEL_STAMP_VERSION).then_some(stamp)
}

pub(super) fn kernel_stamp_config_is_current(root: &Path, stamp: &KernelStamp) -> bool {
    crate::runner_compatibility::package_config(root)
        .and_then(|path| kernel_package_config_key(&path))
        .is_ok_and(|actual| actual == stamp.config_key)
}

pub(super) fn kernel_stamp_is_current(
    root: &Path,
    sdk_root: &Path,
    kernel: &Path,
    depfile: &Path,
    worker: &Path,
) -> bool {
    if !kernel.is_file() {
        return false;
    }
    let Some(stamp) = read_kernel_stamp(kernel) else {
        return false;
    };
    if !kernel_stamp_config_is_current(root, &stamp) {
        return false;
    }
    let Ok((sdk_version, allowed_experiments)) = aot_sdk_identity(sdk_root) else {
        return false;
    };
    if stamp.sdk_version != sdk_version || stamp.allowed_experiments != allowed_experiments {
        return false;
    }
    let Ok(contents) = fs::read_to_string(depfile) else {
        return false;
    };
    let Some(dependencies) = parse_depfile_dependencies(&contents) else {
        return false;
    };
    let mut current = std::collections::BTreeSet::new();
    let mut current_keys = std::collections::BTreeSet::new();
    for dependency in dependencies {
        let Ok(dependency) = canonicalize(dependency) else {
            return false;
        };
        current_keys.insert(dependency.to_string_lossy().into_owned());
        current.insert(dependency);
    }
    if !current.contains(worker) {
        return false;
    }
    let mut digests = crate::validated_digest::Cache::load(root);
    let valid = digests.matches(kernel, &stamp.kernel_digest)
        && stamp.dependencies.iter().all(|(key, expected)| {
            current_keys.contains(key) && digests.matches(Path::new(key), expected)
        });
    if valid {
        digests.save(root);
    }
    valid
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

    let separator = logical.find(": ").or_else(|| logical.find(':'))?;
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
