use crate::pattern::{capture_names, validate_capture_output};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BuildTo {
    Cache,
    Source,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BuilderKind {
    Normal,
    PostProcess,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BuilderExtension {
    pub(crate) input_suffix: String,
    pub(crate) input_is_exact: bool,
    pub(crate) input_is_capture: bool,
    pub(crate) input_is_all: bool,
    pub(crate) input_is_anchored: bool,
    pub(crate) output_suffixes: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) struct BuilderTrigger {
    pub(crate) kind: String,
    pub(crate) value: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BuilderDefinition {
    pub(crate) id: String,
    pub(crate) kind: BuilderKind,
    pub(crate) extensions: Vec<BuilderExtension>,
    pub(crate) post_process_input_extensions: Vec<String>,
    pub(crate) build_to: BuildTo,
    pub(crate) phase: u32,
    pub(crate) is_optional: bool,
    pub(crate) output_is_optional: bool,
    /// All `required_inputs` suffixes from build.yaml, kept losslessly.
    pub(crate) required_input_suffixes: Vec<String>,
    pub(crate) excluded_input_suffixes: Vec<String>,
    pub(crate) applies_builder: Option<String>,
    pub(crate) triggers: Vec<BuilderTrigger>,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ConfiguredBuilder {
    pub(crate) definition: Arc<BuilderDefinition>,
    pub(crate) target: String,
    pub(crate) package: String,
    /// Whether this configured builder belongs to the root package. This is
    /// part of BuilderOptions and can affect the runtime output mapping.
    pub(crate) is_root: bool,
    pub(crate) target_order: u32,
    pub(crate) phase: u32,
    pub(crate) excluded_input_suffixes: Vec<String>,
    pub(crate) generate_for: Vec<String>,
    pub(crate) generate_for_exclude: Vec<String>,
    pub(crate) target_sources: Vec<String>,
    pub(crate) target_sources_exclude: Vec<String>,
    pub(crate) options: BTreeMap<String, Value>,
    /// A per-application runtime mapping. The static definition remains the
    /// build.yaml ordering/identity source, while this mapping is the exact
    /// Builder instance configuration used for planning.
    pub(crate) runtime_extensions: Option<Vec<BuilderExtension>>,
    pub(crate) runtime_post_process_input_extensions: Option<Vec<String>>,
}

impl ConfiguredBuilder {
    pub(crate) fn effective_definition(&self) -> Arc<BuilderDefinition> {
        if self.runtime_extensions.is_none()
            && self.runtime_post_process_input_extensions.is_none()
        {
            return self.definition.clone();
        }
        let mut definition = (*self.definition).clone();
        if let Some(extensions) = &self.runtime_extensions {
            definition.extensions = extensions.clone();
        }
        if let Some(input_extensions) = &self.runtime_post_process_input_extensions {
            definition.post_process_input_extensions = input_extensions.clone();
        }
        Arc::new(definition)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct RustBuildConfig {
    pub(crate) builders: Vec<ConfiguredBuilder>,
    pub(crate) worker_entrypoint: Option<PathBuf>,
    pub(crate) manifest_signature: Option<String>,
    pub(crate) trigger_digest: Option<String>,
    pub(crate) definitions: BTreeMap<String, Arc<BuilderDefinition>>,
}

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

impl RustBuildConfig {
    pub(crate) fn definition(&self, id: &str) -> Option<&BuilderDefinition> {
        self.definitions.get(id).map(Arc::as_ref)
    }

    /// The manifest generator already resolves builder and target ordering into
    /// the configured phase number. Keep this accessor as the single boundary
    /// used by the planner and visibility model.
    pub(crate) fn global_phase(&self, builder: &ConfiguredBuilder) -> u32 {
        builder.phase
    }

    pub(crate) fn phase_count(&self) -> usize {
        let normal_phase_count = self
            .builders
            .iter()
            .filter(|builder| builder.definition.kind == BuilderKind::Normal)
            .map(|builder| self.global_phase(builder))
            .max()
            .map_or(0, |phase| phase.saturating_add(1) as usize);
        let has_post_process = self
            .builders
            .iter()
            .any(|builder| builder.definition.kind == BuilderKind::PostProcess);
        (normal_phase_count + usize::from(has_post_process)).max(1)
    }
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

fn dynamic_builder_definition(entry: BuilderManifestDefinition) -> io::Result<BuilderDefinition> {
    let kind = match entry.kind.as_str() {
        "normal" => BuilderKind::Normal,
        "post_process" => BuilderKind::PostProcess,
        value => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported builder kind for {}: {value}", entry.id),
            ));
        }
    };
    validate_triggers(&entry.id, kind, &entry.triggers)?;
    if kind == BuilderKind::PostProcess {
        let invalid_extension = |value: &str| {
            value.is_empty()
                || !value.starts_with('.')
                || value
                    .chars()
                    .any(|character| matches!(character, '*' | '?' | '{' | '}' | '[' | ']'))
        };
        if entry.input_extensions.is_empty()
            || entry
                .input_extensions
                .iter()
                .any(|extension| invalid_extension(extension))
            || entry.build_to != "cache"
            || !entry.extensions.is_empty()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported post-process metadata for {}", entry.id),
            ));
        }
        return Ok(BuilderDefinition {
            id: entry.id,
            kind,
            extensions: Vec::new(),
            post_process_input_extensions: entry.input_extensions,
            build_to: BuildTo::Cache,
            phase: entry.phase,
            is_optional: false,
            output_is_optional: true,
            required_input_suffixes: Vec::new(),
            excluded_input_suffixes: Vec::new(),
            applies_builder: None,
            triggers: entry.triggers,
        });
    }
    let build_to = match entry.build_to.as_str() {
        "cache" => BuildTo::Cache,
        "source" => BuildTo::Source,
        value => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported build_to for {}: {value}", entry.id),
            ));
        }
    };

    let invalid_suffix = |value: &str| {
        value.is_empty()
            || value
                .chars()
                .any(|character| matches!(character, '*' | '?' | '{' | '}' | '[' | ']'))
    };
    let invalid_path = |value: &str| {
        invalid_suffix(value)
            || value.starts_with('/')
            || value.contains('\\')
            || value.contains('|')
            || value.contains("..")
    };
    let invalid_capture_path = |value: &str| {
        value.is_empty()
            || value.starts_with('/')
            || value.contains('\\')
            || value.contains('|')
            || value.contains("..")
            || value.contains('*')
            || value.contains('?')
            || value.contains('[')
            || value.contains(']')
    };
    let manifest_extensions = if entry.extensions.is_empty() {
        let mut output_suffixes = entry.output_suffixes.clone();
        if output_suffixes.is_empty() {
            if let Some(output_suffix) = &entry.output_suffix {
                output_suffixes.push(output_suffix.clone());
            }
        }
        vec![BuilderManifestExtension {
            input_suffix: entry.input_suffix.clone(),
            input_match: entry.input_match.clone(),
            input_anchored: entry.input_anchored,
            output_suffixes,
        }]
    } else {
        entry.extensions
    };
    if manifest_extensions.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unsupported build extension metadata for {}", entry.id),
        ));
    }

    let mut extensions = Vec::with_capacity(manifest_extensions.len());
    for manifest_extension in manifest_extensions {
        let input_is_all = manifest_extension.input_match == "all";
        let input_is_capture = manifest_extension.input_match == "capture";
        let input_is_exact = match manifest_extension.input_match.as_str() {
            "suffix" | "capture" | "all" => false,
            "exact" => true,
            value => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("unsupported input match for {}: {value}", entry.id),
                ));
            }
        };
        let capture_group_names = if input_is_capture {
            Some(
                capture_names(&manifest_extension.input_suffix).map_err(|error| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!(
                            "unsupported build extension metadata for {}: {error}",
                            entry.id
                        ),
                    )
                })?,
            )
        } else {
            None
        };
        let invalid_input = if input_is_all {
            !manifest_extension.input_suffix.is_empty() || manifest_extension.input_anchored
        } else if input_is_capture {
            invalid_capture_path(&manifest_extension.input_suffix)
        } else if input_is_exact {
            invalid_path(&manifest_extension.input_suffix)
        } else {
            invalid_suffix(&manifest_extension.input_suffix)
        };
        let invalid_output = manifest_extension.output_suffixes.iter().any(|suffix| {
            if input_is_all {
                invalid_suffix(suffix)
            } else if input_is_capture {
                invalid_capture_path(suffix)
                    || validate_capture_output(
                        capture_group_names.as_deref().unwrap_or_default(),
                        suffix,
                    )
                    .is_err()
            } else if input_is_exact {
                invalid_path(suffix)
            } else {
                invalid_suffix(suffix)
            }
        });
        if invalid_input || invalid_output {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported build extension metadata for {}", entry.id),
            ));
        }
        extensions.push(BuilderExtension {
            input_suffix: manifest_extension.input_suffix,
            input_is_exact,
            input_is_capture,
            input_is_all,
            input_is_anchored: manifest_extension.input_anchored,
            output_suffixes: manifest_extension.output_suffixes,
        });
    }

    let required_input_suffixes = entry.required_input_suffixes;
    let invalid_required_input = |suffix: &str| invalid_suffix(suffix) || !suffix.starts_with('.');
    if entry.id.is_empty()
        || required_input_suffixes
            .iter()
            .any(|suffix| invalid_required_input(suffix))
        || entry.excluded_input_suffixes.iter().any(|suffix| {
            if suffix.contains("{{") {
                invalid_capture_path(suffix) || capture_names(suffix).is_err()
            } else {
                invalid_suffix(suffix)
            }
        })
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unsupported build extension metadata for {}", entry.id),
        ));
    }

    Ok(BuilderDefinition {
        id: entry.id,
        kind,
        extensions,
        post_process_input_extensions: Vec::new(),
        build_to,
        phase: entry.phase,
        is_optional: entry.is_optional,
        output_is_optional: entry.output_is_optional,
        required_input_suffixes,
        excluded_input_suffixes: entry.excluded_input_suffixes,
        applies_builder: entry.applies_builder,
        triggers: entry.triggers,
    })
}

fn validate_triggers(
    builder_id: &str,
    kind: BuilderKind,
    triggers: &[BuilderTrigger],
) -> io::Result<()> {
    if kind == BuilderKind::PostProcess && !triggers.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unsupported triggers for post-process builder: {builder_id}"),
        ));
    }
    for trigger in triggers {
        let valid = match trigger.kind.as_str() {
            "import" => valid_import_trigger(&trigger.value),
            "annotation" => valid_annotation_trigger(&trigger.value),
            _ => false,
        };
        if !valid {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "unsupported trigger for {builder_id}: {} {}",
                    trigger.kind, trigger.value
                ),
            ));
        }
    }
    Ok(())
}

fn valid_import_trigger(value: &str) -> bool {
    let mut characters = value.chars();
    characters
        .next()
        .is_some_and(|character| character.is_ascii_lowercase())
        && characters.all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, '_' | '/' | '.')
        })
}

fn valid_annotation_trigger(value: &str) -> bool {
    let mut characters = value.chars();
    characters
        .next()
        .is_some_and(|character| character.is_ascii_alphabetic() || character == '_')
        && characters.all(|character| character.is_ascii_alphanumeric() || character == '_')
}

fn runtime_mapping_from_manifest(
    entry: &BuilderManifestDefinition,
    mapping: BuilderManifestRuntime,
) -> io::Result<(Option<Vec<BuilderExtension>>, Option<Vec<String>>)> {
    let invalid = |message: &str| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid runtime mapping for {}: {message}", entry.id),
        )
    };
    match entry.kind.as_str() {
        "normal" => {
            if mapping.input_extensions.is_some() {
                return Err(invalid("normal builders cannot carry input_extensions"));
            }
            let extensions = mapping
                .extensions
                .ok_or_else(|| invalid("normal builders require extensions"))?;
            let mut runtime_entry = entry.clone();
            runtime_entry.extensions = extensions;
            runtime_entry.input_suffix.clear();
            runtime_entry.output_suffixes.clear();
            runtime_entry.output_suffix = None;
            runtime_entry.runtime_mapping = None;
            let runtime = dynamic_builder_definition(runtime_entry)?;
            Ok((Some(runtime.extensions), None))
        }
        "post_process" => {
            if mapping.extensions.is_some() {
                return Err(invalid("post-process builders cannot carry extensions"));
            }
            let input_extensions = mapping
                .input_extensions
                .ok_or_else(|| invalid("post-process builders require input_extensions"))?;
            let mut runtime_entry = entry.clone();
            runtime_entry.kind = "post_process".to_owned();
            runtime_entry.extensions = Vec::new();
            runtime_entry.input_extensions = input_extensions;
            runtime_entry.runtime_mapping = None;
            runtime_entry.build_to = "cache".to_owned();
            let runtime = dynamic_builder_definition(runtime_entry)?;
            Ok((None, Some(runtime.post_process_input_extensions)))
        }
        kind => Err(invalid(&format!("unsupported builder kind: {kind}"))),
    }
}

fn default_input_match() -> String {
    "suffix".to_owned()
}

fn default_builder_kind() -> String {
    "normal".to_owned()
}

#[cfg(test)]
mod tests {
    use super::{rust_build_config_from_manifest, BuilderManifestFile};
    use crate::builder::BuilderKind;
    use serde_json::json;

    #[test]
    fn dynamic_manifest_preserves_builder_phase_order() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [
                {
                    "id": "example:phase-two",
                    "input_suffix": ".txt",
                    "output_suffixes": [".two"],
                    "build_to": "source",
                    "phase": 1,
                    "target": "example:example",
                    "package": "example",
                    "generate_for": ["lib/**/*.txt"]
                },
                {
                    "id": "example:phase-one",
                    "input_suffix": ".txt",
                    "output_suffixes": [".one"],
                    "build_to": "source",
                    "phase": 0,
                    "target": "example:example",
                    "package": "example",
                    "generate_for": ["lib/**/*.txt"]
                }
            ],
            "definitions": [
                {
                    "id": "example:phase-two",
                    "input_suffix": ".txt",
                    "output_suffixes": [".two"],
                    "build_to": "source",
                    "phase": 1
                },
                {
                    "id": "example:phase-one",
                    "input_suffix": ".txt",
                    "output_suffixes": [".one"],
                    "build_to": "source",
                    "phase": 0
                }
            ]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(
            config
                .builders
                .iter()
                .map(|builder| builder.definition.id.as_str())
                .collect::<Vec<_>>(),
            vec!["example:phase-one", "example:phase-two"]
        );
        assert_eq!(
            config
                .builders
                .iter()
                .map(|builder| builder.definition.phase)
                .collect::<Vec<_>>(),
            vec![0, 1]
        );
    }

    #[test]
    fn configured_phase_is_the_global_worker_phase() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [
                {
                    "id": "example:phase-one",
                    "input_suffix": ".txt",
                    "output_suffixes": [".one"],
                    "build_to": "cache",
                    "phase": 3,
                    "target_order": 0,
                    "target": "example:example",
                    "package": "example",
                    "generate_for": ["lib/**/*.txt"]
                },
                {
                    "id": "example:phase-two",
                    "input_suffix": ".txt",
                    "output_suffixes": [".two"],
                    "build_to": "cache",
                    "phase": 7,
                    "target_order": 0,
                    "target": "example:example",
                    "package": "example",
                    "generate_for": ["lib/**/*.txt"]
                }
            ],
            "definitions": [
                {
                    "id": "example:phase-one",
                    "input_suffix": ".txt",
                    "output_suffixes": [".one"],
                    "build_to": "cache",
                    "phase": 0
                },
                {
                    "id": "example:phase-two",
                    "input_suffix": ".txt",
                    "output_suffixes": [".two"],
                    "build_to": "cache",
                    "phase": 0
                }
            ]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(config.global_phase(&config.builders[0]), 3);
        assert_eq!(config.global_phase(&config.builders[1]), 7);
        assert_eq!(config.phase_count(), 8);
    }

    #[test]
    fn dynamic_manifest_preserves_configured_input_exclusions() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".gen.txt"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "excluded_input_suffixes": [".later.txt"],
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".gen.txt"],
                "build_to": "source",
                "phase": 0,
                "excluded_input_suffixes": [".all.txt"]
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(
            config.builders[0].excluded_input_suffixes,
            [".later.txt"]
        );
        assert_eq!(
            config.builders[0].definition.excluded_input_suffixes,
            [".all.txt"]
        );
    }

    #[test]
    fn dynamic_manifest_preserves_multiple_outputs() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".gen.txt", ".meta.txt"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".gen.txt", ".meta.txt"],
                "build_to": "source",
                "phase": 0
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(
            config.builders[0].definition.extensions[0].output_suffixes,
            vec![".gen.txt", ".meta.txt"]
        );
    }

    #[test]
    fn dynamic_manifest_preserves_all_required_input_suffixes() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".generated"],
                "required_input_suffixes": [".first", ".second"],
                "build_to": "cache",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".generated"],
                "required_input_suffixes": [".first", ".second"],
                "build_to": "cache",
                "phase": 0
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(
            config.builders[0].definition.required_input_suffixes,
            [".first", ".second"]
        );
    }

    #[test]
    fn dynamic_manifest_preserves_optional_builder_flag() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:optional",
                "input_suffix": ".txt",
                "output_suffixes": [".optional.txt"],
                "is_optional": true,
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:optional",
                "input_suffix": ".txt",
                "output_suffixes": [".optional.txt"],
                "is_optional": true,
                "build_to": "source",
                "phase": 0
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert!(config.builders[0].definition.is_optional);
    }

    #[test]
    fn dynamic_manifest_preserves_trigger_metadata_and_digest() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "trigger_digest": "trigger-digest",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:trigger",
                "input_suffix": ".dart",
                "output_suffixes": [".generated.dart"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.dart"],
                "triggers": [
                    {"kind": "import", "value": "example/marker.dart"},
                    {"kind": "annotation", "value": "Marker"}
                ]
            }],
            "definitions": [{
                "id": "example:trigger",
                "input_suffix": ".dart",
                "output_suffixes": [".generated.dart"],
                "build_to": "source",
                "phase": 0,
                "triggers": [
                    {"kind": "import", "value": "example/marker.dart"},
                    {"kind": "annotation", "value": "Marker"}
                ]
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(config.trigger_digest.as_deref(), Some("trigger-digest"));
        assert_eq!(
            config.builders[0].definition.triggers,
            vec![
                super::BuilderTrigger {
                    kind: "import".to_owned(),
                    value: "example/marker.dart".to_owned(),
                },
                super::BuilderTrigger {
                    kind: "annotation".to_owned(),
                    value: "Marker".to_owned(),
                },
            ]
        );
    }

    #[test]
    fn dynamic_manifest_rejects_unsupported_trigger_kind() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:trigger",
                "input_suffix": ".dart",
                "output_suffixes": [".generated.dart"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.dart"]
            }],
            "definitions": [{
                "id": "example:trigger",
                "input_suffix": ".dart",
                "output_suffixes": [".generated.dart"],
                "build_to": "source",
                "phase": 0,
                "triggers": [{"kind": "library", "value": "example/marker.dart"}]
            }]
        }))
        .unwrap();
        let error = rust_build_config_from_manifest(manifest).unwrap_err();
        assert!(error.to_string().contains("unsupported trigger"));
    }

    #[test]
    fn dynamic_manifest_accepts_multiple_extension_mappings() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "extensions": [
                    {
                        "input_suffix": ".txt",
                        "input_match": "suffix",
                        "output_suffixes": [".multi"]
                    },
                    {
                        "input_suffix": "lib/special.txt",
                        "input_match": "exact",
                        "input_anchored": true,
                        "output_suffixes": ["lib/special.generated.txt"]
                    }
                ],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "extensions": [
                    {
                        "input_suffix": ".txt",
                        "output_suffixes": [".multi"]
                    },
                    {
                        "input_suffix": "lib/special.txt",
                        "input_match": "exact",
                        "input_anchored": true,
                        "output_suffixes": ["lib/special.generated.txt"]
                    }
                ],
                "build_to": "source",
                "phase": 0
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(config.builders[0].definition.extensions.len(), 2);
        assert_eq!(
            config.builders[0].definition.extensions[1].output_suffixes,
            ["lib/special.generated.txt"]
        );
        assert!(config.builders[0].definition.extensions[1].input_is_exact);
    }

    #[test]
    fn dynamic_manifest_accepts_all_input_mapping() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:all",
                "extensions": [{
                    "input_suffix": "",
                    "input_match": "all",
                    "output_suffixes": [".all"]
                }],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["**"]
            }],
            "definitions": [{
                "id": "example:all",
                "extensions": [{
                    "input_suffix": "",
                    "input_match": "all",
                    "output_suffixes": [".all"]
                }],
                "build_to": "source",
                "phase": 0
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        let extension = &config.builders[0].definition.extensions[0];
        assert!(extension.input_is_all);
        assert!(!extension.input_is_exact);
        assert!(!extension.input_is_capture);
        assert_eq!(extension.input_suffix, "");
    }

    #[test]
    fn dynamic_manifest_rejects_non_empty_all_input_metadata() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:all",
                "input_suffix": ".dart",
                "input_match": "all",
                "output_suffixes": [".all"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["**"]
            }],
            "definitions": [{
                "id": "example:all",
                "input_suffix": ".dart",
                "input_match": "all",
                "output_suffixes": [".all"],
                "build_to": "source",
                "phase": 0
            }]
        }))
        .unwrap();
        let error = rust_build_config_from_manifest(manifest).unwrap_err();
        assert!(error.to_string().contains("unsupported build extension metadata"));
    }

    #[test]
    fn dynamic_manifest_accepts_post_process_definition() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:post",
                "kind": "post_process",
                "input_extensions": [".gen.txt"],
                "build_to": "cache",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.gen.txt"]
            }],
            "definitions": [{
                "id": "example:post",
                "kind": "post_process",
                "input_extensions": [".gen.txt"],
                "build_to": "cache",
                "phase": 0
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(config.builders[0].definition.kind, BuilderKind::PostProcess);
        assert_eq!(
            config.builders[0]
                .definition
                .post_process_input_extensions,
            [".gen.txt"]
        );
        assert!(config.builders[0].definition.extensions.is_empty());
        assert!(config.builders[0].definition.output_is_optional);
    }

    #[test]
    fn singular_output_field_is_accepted_during_manifest_transition() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffix": ".gen.txt",
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffix": ".gen.txt",
                "build_to": "source",
                "phase": 0
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(
            config.builders[0].definition.extensions[0].output_suffixes,
            [".gen.txt"]
        );
    }

    #[test]
    fn dynamic_manifest_accepts_capture_mapping() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:capture",
                "input_suffix": "lib/assets/{{dir}}/{{file}}.txt",
                "input_match": "capture",
                "input_anchored": true,
                "output_suffixes": ["lib/generated/{{dir}}/{{file}}.dart"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/assets/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:capture",
                "input_suffix": "lib/assets/{{dir}}/{{file}}.txt",
                "input_match": "capture",
                "input_anchored": true,
                "output_suffixes": ["lib/generated/{{dir}}/{{file}}.dart"],
                "build_to": "source",
                "phase": 0
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert!(config.builders[0].definition.extensions[0].input_is_capture);
        assert!(config.builders[0].definition.extensions[0].input_is_anchored);
    }
    #[test]
    fn dynamic_manifest_preserves_per_application_runtime_mapping() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".dart",
                "output_suffixes": [".static"],
                "build_to": "cache",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "is_root": false,
                "generate_for": ["**"],
                "runtime_mapping": {
                    "extensions": [{
                        "input_suffix": ".dart",
                        "output_suffixes": [".runtime"]
                    }]
                }
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".dart",
                "output_suffixes": [".static"],
                "build_to": "cache",
                "phase": 0
            }]
        })).unwrap();

        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert!(!config.builders[0].is_root);
        assert_eq!(
            config.builders[0].definition.extensions[0].output_suffixes,
            [".static".to_owned()]
        );
        assert_eq!(
            config.builders[0]
                .effective_definition()
                .extensions[0]
                .output_suffixes,
            [".runtime"]
        );
    }

}
