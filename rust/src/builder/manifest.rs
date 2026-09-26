use super::model::{BuilderTrigger, ConfiguredBuilder, RustBuildConfig};
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
    pub(crate) trigger_digest: String,
    #[serde(default)]
    pub(crate) builders: Vec<BuilderManifestDefinition>,
    #[serde(default)]
    pub(crate) definitions: Vec<BuilderManifestDefinition>,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct BuilderManifestExtension {
    #[serde(default)]
    pub(crate) input_suffix: String,
    #[serde(default = "default_input_match")]
    pub(crate) input_match: String,
    #[serde(default)]
    pub(crate) input_anchored: bool,
    #[serde(default)]
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
    #[serde(default = "default_builder_kind")]
    pub(crate) kind: String,
    #[serde(default)]
    pub(crate) input_suffix: String,
    #[serde(default = "default_input_match")]
    pub(crate) input_match: String,
    #[serde(default)]
    pub(crate) input_anchored: bool,
    #[serde(default)]
    pub(crate) output_suffixes: Vec<String>,
    // Read the flattened fields for compatibility with the v4-shaped v5
    // payload. New manifests use extensions.
    #[serde(default)]
    pub(crate) output_suffix: Option<String>,
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
    #[serde(default)]
    pub(crate) is_optional: bool,
    #[serde(default)]
    pub(crate) output_is_optional: bool,
    #[serde(default)]
    pub(crate) required_input_suffixes: Vec<String>,
    #[serde(default)]
    pub(crate) excluded_input_suffixes: Vec<String>,
    #[serde(default)]
    pub(crate) applies_builder: Option<String>,
    #[serde(default)]
    pub(crate) generate_for: Vec<String>,
    #[serde(default)]
    pub(crate) generate_for_exclude: Vec<String>,
    #[serde(default)]
    pub(crate) target_sources: Vec<String>,
    #[serde(default)]
    pub(crate) target_sources_exclude: Vec<String>,
    #[serde(default)]
    pub(crate) options: BTreeMap<String, Value>,
    #[serde(default)]
    pub(crate) target: String,
    #[serde(default)]
    pub(crate) package: String,
    #[serde(default)]
    pub(crate) is_root: bool,
    #[serde(default)]
    pub(crate) target_order: u32,
    #[serde(default)]
    pub(crate) triggers: Vec<BuilderTrigger>,
}

pub(crate) fn rust_build_config_from_manifest(
    manifest: BuilderManifestFile,
) -> io::Result<RustBuildConfig> {
    if manifest.version != 8 {
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
    if definitions.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "builder manifest has no compatible builder definitions",
        ));
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
        builders.push(ConfiguredBuilder {
            definition,
            target: entry.target,
            package: entry.package,
            is_root: entry.is_root,
            target_order: entry.target_order,
            phase: entry.phase,
            excluded_input_suffixes: entry.excluded_input_suffixes,
            generate_for: entry.generate_for,
            generate_for_exclude: entry.generate_for_exclude,
            target_sources: entry.target_sources,
            target_sources_exclude: entry.target_sources_exclude,
            options: entry.options,
            runtime_extensions,
            runtime_post_process_input_extensions,
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

fn default_input_match() -> String {
    "suffix".to_owned()
}

fn default_builder_kind() -> String {
    "normal".to_owned()
}
