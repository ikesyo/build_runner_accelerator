use crate::pattern::{capture_names, validate_capture_output};
use serde::Deserialize;
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
    pub(crate) input_is_anchored: bool,
    pub(crate) output_suffixes: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BuilderDefinition {
    pub(crate) id: String,
    pub(crate) kind: BuilderKind,
    pub(crate) extensions: Vec<BuilderExtension>,
    pub(crate) post_process_input_extensions: Vec<String>,
    pub(crate) build_to: BuildTo,
    pub(crate) phase: u32,
    pub(crate) output_is_optional: bool,
    pub(crate) required_input_suffix: Option<String>,
    pub(crate) excluded_input_suffixes: Vec<String>,
    pub(crate) applies_builder: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ConfiguredBuilder {
    pub(crate) definition: Arc<BuilderDefinition>,
    pub(crate) target: String,
    pub(crate) package: String,
    pub(crate) target_order: u32,
    pub(crate) phase: u32,
    pub(crate) generate_for: Vec<String>,
    pub(crate) generate_for_exclude: Vec<String>,
    pub(crate) target_sources: Vec<String>,
    pub(crate) target_sources_exclude: Vec<String>,
    pub(crate) options: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct RustBuildConfig {
    pub(crate) builders: Vec<ConfiguredBuilder>,
    pub(crate) worker_entrypoint: Option<PathBuf>,
    pub(crate) manifest_signature: Option<String>,
    pub(crate) definitions: BTreeMap<String, Arc<BuilderDefinition>>,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct BuilderManifestFile {
    pub(crate) version: u32,
    pub(crate) fingerprint: String,
    pub(crate) worker_entrypoint: String,
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
    pub(crate) build_to: String,
    pub(crate) phase: u32,
    #[serde(default)]
    pub(crate) output_is_optional: bool,
    #[serde(default)]
    pub(crate) required_input_suffix: Option<String>,
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
    pub(crate) target_order: u32,
}

impl RustBuildConfig {
    pub(crate) fn definition(&self, id: &str) -> Option<&BuilderDefinition> {
        self.definitions.get(id).map(Arc::as_ref)
    }
}

pub(crate) fn rust_build_config_from_manifest(
    manifest: BuilderManifestFile,
) -> io::Result<RustBuildConfig> {
    if manifest.version != 6 {
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
        builders.push(ConfiguredBuilder {
            definition,
            target: entry.target,
            package: entry.package,
            target_order: entry.target_order,
            phase: entry.phase,
            generate_for: entry.generate_for,
            generate_for_exclude: entry.generate_for_exclude,
            target_sources: entry.target_sources,
            target_sources_exclude: entry.target_sources_exclude,
            options: entry.options,
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
            output_is_optional: true,
            required_input_suffix: None,
            excluded_input_suffixes: Vec::new(),
            applies_builder: None,
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
        let input_is_capture = manifest_extension.input_match == "capture";
        let input_is_exact = match manifest_extension.input_match.as_str() {
            "suffix" | "capture" => false,
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
        let invalid_input = if input_is_capture {
            invalid_capture_path(&manifest_extension.input_suffix)
        } else if input_is_exact {
            invalid_path(&manifest_extension.input_suffix)
        } else {
            invalid_suffix(&manifest_extension.input_suffix)
        };
        let invalid_output = manifest_extension.output_suffixes.iter().any(|suffix| {
            if input_is_capture {
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
        if invalid_input || manifest_extension.output_suffixes.is_empty() || invalid_output {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported build extension metadata for {}", entry.id),
            ));
        }
        extensions.push(BuilderExtension {
            input_suffix: manifest_extension.input_suffix,
            input_is_exact,
            input_is_capture,
            input_is_anchored: manifest_extension.input_anchored,
            output_suffixes: manifest_extension.output_suffixes,
        });
    }

    if entry.id.is_empty()
        || entry
            .required_input_suffix
            .as_deref()
            .is_some_and(invalid_suffix)
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
        output_is_optional: entry.output_is_optional,
        required_input_suffix: entry.required_input_suffix,
        excluded_input_suffixes: entry.excluded_input_suffixes,
        applies_builder: entry.applies_builder,
    })
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
            "version": 6,
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
    fn dynamic_manifest_preserves_multiple_outputs() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 6,
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
    fn dynamic_manifest_accepts_multiple_extension_mappings() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 6,
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
    fn dynamic_manifest_accepts_post_process_definition() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 6,
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
            "version": 6,
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
            "version": 6,
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
}
