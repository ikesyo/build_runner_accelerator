use super::manifest::{
    BuilderManifestDefinition, BuilderManifestExtension, BuilderManifestRuntime,
};
use super::model::{
    BuildTo, BuilderDefinition, BuilderExtension, BuilderKind, BuilderTrigger,
};
use crate::pattern::{capture_names, validate_capture_output};
use std::io;

pub(super) fn dynamic_builder_definition(entry: BuilderManifestDefinition) -> io::Result<BuilderDefinition> {
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
        let build_to = match entry.build_to.as_str() {
            "cache" => BuildTo::Cache,
            "source" => BuildTo::Source,
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("unsupported post-process metadata for {}", entry.id),
                ));
            }
        };
        if entry.input_extensions.is_empty()
            || entry
                .input_extensions
                .iter()
                .any(|extension| invalid_extension(extension))
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
            build_to,
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

pub(super) fn runtime_mapping_from_manifest(
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
            let runtime = dynamic_builder_definition(runtime_entry)?;
            Ok((None, Some(runtime.post_process_input_extensions)))
        }
        kind => Err(invalid(&format!("unsupported builder kind: {kind}"))),
    }
}
