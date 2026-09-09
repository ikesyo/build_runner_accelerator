use crate::builder::{BuildTo, RustBuildConfig};
use crate::digest::digest_bytes;
use crate::graph::GraphState;
use crate::plan::output_path;
use crate::snapshot::{glob_asset_key, glob_digest, AssetSnapshot, Snapshot};
use crate::workspace::Workspace;
use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::Path;

pub(crate) fn add_current_generated_assets(
    workspace: &Workspace,
    state: &GraphState,
    snapshot: &mut Snapshot,
    config: &RustBuildConfig,
) -> io::Result<()> {
    for action in state.actions.values() {
        let Some(builder) = config.definition(&action.builder) else {
            continue;
        };
        for output in &action.outputs {
            let path = output_path(workspace, builder, output)?;
            if let Ok(bytes) = fs::read(&path) {
                snapshot.insert(
                    output.clone(),
                    AssetSnapshot {
                        exists: true,
                        digest: digest_bytes(&bytes),
                        size: bytes.len() as u64,
                    },
                );
            }
        }
    }
    Ok(())
}

pub(crate) fn add_tracked_dependency_assets(
    workspace: &Workspace,
    state: &GraphState,
    snapshot: &mut Snapshot,
) -> io::Result<()> {
    let dependencies = state.actions.values().flat_map(|action| {
        std::iter::once(&action.input)
            .chain(action.reads.iter())
            .chain(action.resolver_reads.iter())
    });
    for asset in dependencies {
        if snapshot.contains_key(asset) {
            continue;
        }
        match workspace.read_asset_or_cache(asset) {
            Ok(bytes) => {
                snapshot.insert(
                    asset.clone(),
                    AssetSnapshot {
                        exists: true,
                        digest: digest_bytes(&bytes),
                        size: bytes.len() as u64,
                    },
                );
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                snapshot.insert(
                    asset.clone(),
                    AssetSnapshot {
                        exists: false,
                        digest: digest_bytes(b"<missing>"),
                        size: 0,
                    },
                );
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

pub(crate) fn add_tracked_glob_assets(
    workspace: &Workspace,
    state: &GraphState,
    snapshot: &mut Snapshot,
) -> io::Result<()> {
    let globs = state
        .actions
        .values()
        .flat_map(|action| action.glob_reads.iter())
        .cloned()
        .collect::<BTreeSet<_>>();

    for glob in globs {
        let assets = match workspace.find_assets(&glob.package, &glob.pattern) {
            Ok(assets) => assets,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error),
        };
        let mut matched = Vec::with_capacity(assets.len());
        for asset in assets {
            let digest = if let Some(entry) = snapshot.get(&asset) {
                entry.digest.clone()
            } else {
                match workspace.read_asset_or_cache(&asset) {
                    Ok(bytes) => {
                        let digest = digest_bytes(&bytes);
                        snapshot.insert(
                            asset.clone(),
                            AssetSnapshot {
                                exists: true,
                                digest: digest.clone(),
                                size: bytes.len() as u64,
                            },
                        );
                        digest
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                    Err(error) => return Err(error),
                }
            };
            matched.push(format!("{asset}\0{digest}"));
        }
        matched.sort();
        let serialized_size = matched.iter().map(String::len).sum::<usize>();
        snapshot.insert(
            glob_asset_key(&glob),
            AssetSnapshot {
                exists: true,
                digest: glob_digest(&matched),
                size: serialized_size as u64,
            },
        );
    }
    Ok(())
}

pub(crate) fn config_digest(workspace: &Workspace, config: &RustBuildConfig) -> io::Result<String> {
    let build_yaml = workspace.root.join("build.yaml");
    let mut bytes = fs::read(build_yaml).unwrap_or_default();
    bytes.extend_from_slice(
        &fs::read(workspace.root.join(".dart_tool/package_config.json")).unwrap_or_default(),
    );
    if let Some(signature) = &config.manifest_signature {
        bytes.extend_from_slice(signature.as_bytes());
    }
    for builder in &config.builders {
        bytes.extend_from_slice(builder.target.as_bytes());
        bytes.push(0);
        bytes.extend_from_slice(builder.package.as_bytes());
        bytes.push(0);
        bytes.extend_from_slice(&builder.target_order.to_be_bytes());
        bytes.extend_from_slice(&builder.phase.to_be_bytes());
        bytes.extend_from_slice(builder.definition.id.as_bytes());
        bytes.push(match builder.definition.kind {
            crate::builder::BuilderKind::Normal => 0,
            crate::builder::BuilderKind::PostProcess => 1,
        });
        for input_extension in &builder.definition.post_process_input_extensions {
            bytes.extend_from_slice(input_extension.as_bytes());
            bytes.push(0);
        }
        for extension in &builder.definition.extensions {
            bytes.extend_from_slice(extension.input_suffix.as_bytes());
            bytes.push(u8::from(extension.input_is_exact));
            bytes.push(u8::from(extension.input_is_capture));
            bytes.push(u8::from(extension.input_is_anchored));
            for suffix in &extension.output_suffixes {
                bytes.extend_from_slice(suffix.as_bytes());
                bytes.push(0);
            }
            bytes.push(0);
        }
        bytes.extend_from_slice(&builder.definition.phase.to_be_bytes());
        bytes.push(u8::from(builder.definition.output_is_optional));
        bytes.push(match builder.definition.build_to {
            BuildTo::Cache => 0,
            BuildTo::Source => 1,
        });
        bytes.extend_from_slice(
            builder
                .definition
                .required_input_suffix
                .as_deref()
                .unwrap_or_default()
                .as_bytes(),
        );
        for pattern in &builder.generate_for {
            bytes.extend_from_slice(pattern.as_bytes());
            bytes.push(0);
        }
        for pattern in &builder.generate_for_exclude {
            bytes.extend_from_slice(pattern.as_bytes());
            bytes.push(0);
        }
        for pattern in &builder.target_sources {
            bytes.extend_from_slice(pattern.as_bytes());
            bytes.push(0);
        }
        for pattern in &builder.target_sources_exclude {
            bytes.extend_from_slice(pattern.as_bytes());
            bytes.push(0);
        }
        if let Ok(options) = serde_json::to_vec(&builder.options) {
            bytes.extend_from_slice(&options);
        }
    }
    Ok(digest_bytes(&bytes))
}

pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("output has no parent"))?;
    fs::create_dir_all(parent)?;
    if path.is_file() && fs::read(path)? == bytes {
        return Ok(());
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("output");
    let temporary = parent.join(format!(
        ".{file_name}.build-runner-accelerator-{}.tmp",
        std::process::id()
    ));
    fs::write(&temporary, bytes)?;
    fs::rename(temporary, path)
}
