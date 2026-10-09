use super::model::{BuildTo, BuilderKind, BuilderTrigger, ConfiguredBuilder, RustBuildConfig};
use super::validation::{dynamic_builder_definition, runtime_mapping_from_manifest};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct BuilderManifestFile {
    pub(crate) version: u32,
    pub(crate) fingerprint: String,
    pub(crate) worker_entrypoint: String,
    #[serde(default)]
    pub(crate) worker_source_digest: Option<String>,
    pub(crate) trigger_digest: String,
    pub(crate) builders: Vec<BuilderManifestDefinition>,
    pub(crate) definitions: Vec<BuilderManifestDefinition>,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct BuilderManifestExtension {
    pub(crate) input_suffix: String,
    pub(crate) input_match: String,
    pub(crate) input_anchored: bool,
    pub(crate) output_suffixes: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct BuilderManifestRuntime {
    #[serde(default)]
    pub(crate) extensions: Option<Vec<BuilderManifestExtension>>,
    #[serde(default)]
    pub(crate) input_extensions: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct BuilderManifestDefinition {
    pub(crate) id: String,
    pub(crate) kind: String,
    #[serde(default)]
    pub(crate) extensions: Vec<BuilderManifestExtension>,
    #[serde(default)]
    pub(crate) input_extensions: Vec<String>,
    /// Runtime mapping captured from the factory with the resolved options.
    ///
    /// build.yaml controls ordering, but build_runner plans expected outputs
    /// from the instantiated Builder. Keep that distinction explicit at the
    /// manifest boundary so Rust never guesses package-specific behavior.
    #[serde(default)]
    pub(crate) runtime_mapping: Option<BuilderManifestRuntime>,
    pub(crate) build_to: String,
    pub(crate) phase: u32,
    pub(crate) is_optional: bool,
    pub(crate) output_is_optional: bool,
    pub(crate) required_input_suffixes: Vec<String>,
    pub(crate) excluded_input_suffixes: Vec<String>,
    #[serde(default)]
    pub(crate) applies_builder: Option<String>,
    pub(crate) generate_for: Vec<String>,
    pub(crate) generate_for_exclude: Vec<String>,
    pub(crate) target_sources: Vec<String>,
    pub(crate) target_sources_exclude: Vec<String>,
    pub(crate) options: serde_json::Map<String, Value>,
    #[serde(default)]
    pub(crate) target: String,
    #[serde(default)]
    pub(crate) package: String,
    #[serde(default)]
    pub(crate) is_root: Option<bool>,
    #[serde(default)]
    pub(crate) target_order: Option<u32>,
    pub(crate) triggers: Vec<BuilderTrigger>,
    #[serde(default)]
    pub(crate) part_directive_suffix: Option<String>,
}

pub(crate) fn rust_build_config_from_manifest(
    manifest: BuilderManifestFile,
) -> io::Result<RustBuildConfig> {
    if manifest.version != 9 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unsupported builder manifest version: {}", manifest.version),
        ));
    }
    if manifest.worker_entrypoint.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "builder manifest has no worker entrypoint",
        ));
    }

    let mut definitions = BTreeMap::new();
    for entry in manifest.definitions {
        let definition = Arc::new(dynamic_builder_definition(entry)?);
        if definitions
            .insert(definition.id.clone(), definition)
            .is_some()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "builder manifest contains duplicate definitions",
            ));
        }
    }
    let mut builders = Vec::new();
    for entry in manifest.builders {
        let definition = definitions.get(entry.id.as_str()).cloned().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "configured builder is missing from definitions: {}",
                    entry.id
                ),
            )
        })?;
        let expected_kind = match definition.kind {
            BuilderKind::Normal => "normal",
            BuilderKind::PostProcess => "post_process",
        };
        let expected_build_to = match definition.build_to {
            BuildTo::Source => "source",
            BuildTo::Cache => "cache",
        };
        if entry.kind != expected_kind || entry.build_to != expected_build_to {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "configured builder metadata disagrees with definition: {} (kind/build_to)",
                    entry.id
                ),
            ));
        }
        if entry.generate_for.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("configured builder has no generate_for: {}", entry.id),
            ));
        }
        if entry.target.is_empty() || entry.package.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("configured builder has no target scope: {}", entry.id),
            ));
        }
        let (runtime_extensions, runtime_post_process_input_extensions) =
            match entry.runtime_mapping.clone() {
                Some(mapping) => runtime_mapping_from_manifest(&entry, mapping)?,
                None => (None, None),
            };
        if let Some(suffix) = &entry.part_directive_suffix {
            let valid = suffix.starts_with('.')
                && suffix.len() > 1
                && !suffix.chars().any(|c| {
                    matches!(
                        c,
                        '*' | '?' | '{' | '}' | '[' | ']' | '/' | '\\' | '|' | '\'' | '"'
                    )
                });
            if !valid {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!(
                        "unsupported part_directive_suffix for {}: {suffix}",
                        entry.id
                    ),
                ));
            }
        }
        builders.push(ConfiguredBuilder {
            definition,
            target: entry.target,
            package: entry.package,
            is_root: entry.is_root.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "configured builder requires is_root",
                )
            })?,
            target_order: entry.target_order.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "configured builder requires target_order",
                )
            })?,
            phase: entry.phase,
            excluded_input_suffixes: entry.excluded_input_suffixes,
            generate_for: entry.generate_for,
            generate_for_exclude: entry.generate_for_exclude,
            target_sources: entry.target_sources,
            target_sources_exclude: entry.target_sources_exclude,
            options: entry.options,
            runtime_extensions,
            runtime_post_process_input_extensions,
            part_directive_suffix: entry.part_directive_suffix,
        });
    }
    builders.sort_by_key(|builder| {
        (
            builder.target_order,
            builder.phase,
            builder.target.clone(),
            builder.definition.id.clone(),
        )
    });

    Ok(RustBuildConfig {
        builders,
        worker_entrypoint: Some(PathBuf::from(manifest.worker_entrypoint)),
        manifest_signature: Some(manifest.fingerprint),
        trigger_digest: Some(manifest.trigger_digest),
        definitions,
    })
}
