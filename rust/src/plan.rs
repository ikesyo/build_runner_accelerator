use crate::builder::{
    BuildTo, BuilderDefinition, BuilderExtension, BuilderKind, ConfiguredBuilder, RustBuildConfig,
};
use crate::digest::digest_bytes;
use crate::pattern::{expand_capture_template, match_capture_pattern};
use crate::snapshot::Snapshot;
use crate::workspace::{matches_glob, Workspace};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct BuildSpec {
    pub(crate) builder: Arc<BuilderDefinition>,
    pub(crate) target: String,
    pub(crate) package: String,
    pub(crate) phase: u32,
    pub(crate) instance_key: String,
    pub(crate) input: String,
    pub(crate) outputs: Vec<String>,
    pub(crate) options: BTreeMap<String, Value>,
}

pub(crate) fn input_candidates(
    _workspace: &Workspace,
    snapshot: &Snapshot,
    builder: &ConfiguredBuilder,
) -> BTreeSet<String> {
    let prefix = format!("{}|", builder.package);
    snapshot
        .keys()
        .filter_map(|asset| {
            let path = asset.strip_prefix(&prefix)?;
            if !snapshot.get(asset).is_some_and(|entry| entry.exists) {
                return None;
            }
            let matches_extension = if builder.definition.kind == BuilderKind::PostProcess {
                builder
                    .definition
                    .post_process_input_extensions
                    .iter()
                    .any(|extension| path.ends_with(extension))
            } else {
                builder
                    .definition
                    .extensions
                    .iter()
                    .any(|extension| extension_matches(extension, path))
            };
            let excluded = builder
                .excluded_input_suffixes
                .iter()
                .any(|suffix| {
                    if suffix.contains("{{") {
                        match_capture_pattern(path, suffix, false).is_some()
                    } else {
                        path.ends_with(suffix.as_str())
                    }
                });
            let matches_generate_for = builder
                .generate_for
                .iter()
                .any(|pattern| matches_glob(pattern, path));
            let excluded_by_generate_for = builder
                .generate_for_exclude
                .iter()
                .any(|pattern| matches_glob(pattern, path));
            let matches_target_sources = builder
                .target_sources
                .iter()
                .any(|pattern| matches_glob(pattern, path));
            let excluded_by_target_sources = builder
                .target_sources_exclude
                .iter()
                .any(|pattern| matches_glob(pattern, path));
            (matches_extension
                && !excluded
                && matches_generate_for
                && !excluded_by_generate_for
                && matches_target_sources
                && !excluded_by_target_sources)
                .then_some(asset.clone())
        })
        .collect()
}

pub(crate) fn build_specs_for_kind(
    workspace: &Workspace,
    snapshot: &Snapshot,
    config: &RustBuildConfig,
    kind: Option<BuilderKind>,
) -> io::Result<Vec<BuildSpec>> {
    build_specs(workspace, snapshot, config, kind, None)
}

/// Creates the actions for one manifest phase. A later phase receives a
/// snapshot augmented by the previous phase's declared outputs, matching
/// build_runner's rule that generated assets become visible only after their
/// phase completes.
pub(crate) fn build_specs_for_phase(
    workspace: &Workspace,
    snapshot: &Snapshot,
    config: &RustBuildConfig,
    kind: BuilderKind,
    phase: u32,
) -> io::Result<Vec<BuildSpec>> {
    build_specs(workspace, snapshot, config, Some(kind), Some(phase))
}

fn build_specs(
    workspace: &Workspace,
    snapshot: &Snapshot,
    config: &RustBuildConfig,
    kind: Option<BuilderKind>,
    phase: Option<u32>,
) -> io::Result<Vec<BuildSpec>> {
    let mut specs = Vec::new();
    for builder in &config.builders {
        if kind.is_some_and(|expected| builder.definition.kind != expected) {
            continue;
        }
        if phase.is_some_and(|expected| builder.phase != expected) {
            continue;
        }
        for input in input_candidates(workspace, snapshot, builder) {
            specs.push(BuildSpec {
                builder: builder.definition.clone(),
                target: builder.target.clone(),
                package: builder.package.clone(),
                phase: builder.phase,
                instance_key: format!(
                    "{}|{}|{}|{}",
                    builder.target, builder.definition.id, builder.phase, builder.package
                ),
                input: input.clone(),
                outputs: if builder.definition.kind == BuilderKind::PostProcess {
                    Vec::new()
                } else {
                    outputs_for(&builder.definition, &input)?
                },
                options: builder.options.clone(),
            });
        }
    }
    validate_unique_outputs(&specs)?;
    Ok(specs)
}

pub(crate) fn validate_unique_outputs(specs: &[BuildSpec]) -> io::Result<()> {
    let mut owners = BTreeMap::new();
    for spec in specs {
        let action = scoped_action_key(&spec.target, &spec.builder.id, &spec.input);
        for output in &spec.outputs {
            if let Some(previous) = owners.insert(output.clone(), action.clone()) {
                return Err(io::Error::other(format!(
                    "builder outputs collide: {output} ({previous} and {action})"
                )));
            }
        }
    }
    Ok(())
}

pub(crate) fn scoped_action_key(target: &str, builder: &str, input: &str) -> String {
    format!("{target}|{builder}|{input}")
}

pub(crate) fn outputs_for(builder: &BuilderDefinition, input: &str) -> io::Result<Vec<String>> {
    let (_, path) = input
        .split_once('|')
        .ok_or_else(|| io::Error::other(format!("invalid AssetId: {input}")))?;
    let mut outputs = Vec::new();
    let mut seen = BTreeSet::new();
    for extension in &builder.extensions {
        if !extension_matches(extension, path) {
            continue;
        }
        for suffix in &extension.output_suffixes {
            let output = output_for(extension, input, suffix)?;
            if seen.insert(output.clone()) {
                outputs.push(output);
            }
        }
    }
    if outputs.is_empty() {
        return Err(io::Error::other(format!(
            "input does not match any build extension: {input}"
        )));
    }
    Ok(outputs)
}

fn extension_matches(extension: &BuilderExtension, path: &str) -> bool {
    if extension.input_is_exact {
        return path == extension.input_suffix;
    }
    if extension.input_is_capture {
        return match_capture_pattern(path, &extension.input_suffix, extension.input_is_anchored)
            .is_some();
    }
    path.ends_with(extension.input_suffix.as_str())
}

fn output_for(
    extension: &BuilderExtension,
    input: &str,
    output_suffix: &str,
) -> io::Result<String> {
    if extension.input_is_exact {
        let (package, path) = input
            .split_once('|')
            .ok_or_else(|| io::Error::other(format!("invalid AssetId: {input}")))?;
        if path != extension.input_suffix {
            return Err(io::Error::other(format!(
                "input does not match {}: {input}",
                extension.input_suffix
            )));
        }
        return Ok(format!("{package}|{output_suffix}"));
    }
    if extension.input_is_capture {
        let (package, path) = input
            .split_once('|')
            .ok_or_else(|| io::Error::other(format!("invalid AssetId: {input}")))?;
        let matched =
            match_capture_pattern(path, &extension.input_suffix, extension.input_is_anchored)
                .ok_or_else(|| {
                    io::Error::other(format!(
                        "input does not match capture pattern {}: {input}",
                        extension.input_suffix
                    ))
                })?;
        let names = crate::pattern::capture_names(&extension.input_suffix)
            .map_err(|error| io::Error::other(error.to_string()))?;
        let resolved_output = expand_capture_template(output_suffix, &names, &matched.values)
            .ok_or_else(|| {
                io::Error::other(format!(
                    "output does not match capture pattern: {output_suffix}"
                ))
            })?;
        return Ok(format!(
            "{package}|{}{}",
            &path[..matched.start],
            resolved_output
        ));
    }
    if !input.ends_with(extension.input_suffix.as_str()) {
        return Err(io::Error::other(format!(
            "input does not end with {}: {input}",
            extension.input_suffix
        )));
    }
    let stem = input
        .strip_suffix(extension.input_suffix.as_str())
        .ok_or_else(|| {
            io::Error::other(format!(
                "input does not end with {}: {input}",
                extension.input_suffix
            ))
        })?;
    Ok(format!("{stem}{output_suffix}"))
}

pub(crate) fn output_path(
    workspace: &Workspace,
    builder: &BuilderDefinition,
    asset: &str,
) -> io::Result<PathBuf> {
    match builder.build_to {
        BuildTo::Cache => workspace.cache_path_for_asset(asset),
        BuildTo::Source => workspace.path_for_asset(asset),
    }
}

pub(crate) fn output_digest(
    workspace: &Workspace,
    builder: &BuilderDefinition,
    asset: &str,
) -> io::Result<Option<String>> {
    match fs::read(output_path(workspace, builder, asset)?) {
        Ok(bytes) => Ok(Some(digest_bytes(&bytes))),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::{outputs_for, validate_unique_outputs, BuildSpec};
    use crate::builder::{BuildTo, BuilderDefinition, BuilderExtension, BuilderKind};
    use std::collections::BTreeMap;
    use std::sync::Arc;

    #[test]
    fn outputs_for_uses_builder_definition_metadata() {
        let builder = Arc::new(BuilderDefinition {
            id: "example:builder".to_owned(),
            kind: BuilderKind::Normal,
            extensions: vec![BuilderExtension {
                input_suffix: ".dart".to_owned(),
                input_is_exact: false,
                input_is_capture: false,
                input_is_anchored: false,
                output_suffixes: vec![".one.dart".to_owned(), ".two.dart".to_owned()],
            }],
            post_process_input_extensions: Vec::new(),
            build_to: BuildTo::Source,
            phase: 0,
            output_is_optional: false,
            required_input_suffix: None,
            excluded_input_suffixes: Vec::new(),
            applies_builder: None,
        });
        assert_eq!(
            outputs_for(&builder, "app|lib/model.dart").unwrap(),
            vec!["app|lib/model.one.dart", "app|lib/model.two.dart"]
        );
    }

    #[test]
    fn exact_input_outputs_preserve_package_and_use_literal_paths() {
        let builder = Arc::new(BuilderDefinition {
            id: "example:builder".to_owned(),
            kind: BuilderKind::Normal,
            extensions: vec![BuilderExtension {
                input_suffix: "lib/special.txt".to_owned(),
                input_is_exact: true,
                input_is_capture: false,
                input_is_anchored: true,
                output_suffixes: vec!["lib/special.generated.txt".to_owned()],
            }],
            post_process_input_extensions: Vec::new(),
            build_to: BuildTo::Source,
            phase: 0,
            output_is_optional: false,
            required_input_suffix: None,
            excluded_input_suffixes: Vec::new(),
            applies_builder: None,
        });
        assert_eq!(
            outputs_for(&builder, "app|lib/special.txt").unwrap(),
            vec!["app|lib/special.generated.txt"]
        );
    }

    #[test]
    fn multiple_mappings_union_outputs_for_overlapping_input() {
        let builder = Arc::new(BuilderDefinition {
            id: "example:builder".to_owned(),
            kind: BuilderKind::Normal,
            extensions: vec![
                BuilderExtension {
                    input_suffix: ".txt".to_owned(),
                    input_is_exact: false,
                    input_is_capture: false,
                    input_is_anchored: false,
                    output_suffixes: vec![".multi".to_owned()],
                },
                BuilderExtension {
                    input_suffix: "lib/special.txt".to_owned(),
                    input_is_exact: true,
                    input_is_capture: false,
                    input_is_anchored: true,
                    output_suffixes: vec!["lib/special.generated.txt".to_owned()],
                },
            ],
            post_process_input_extensions: Vec::new(),
            build_to: BuildTo::Source,
            phase: 0,
            output_is_optional: false,
            required_input_suffix: None,
            excluded_input_suffixes: Vec::new(),
            applies_builder: None,
        });
        assert_eq!(
            outputs_for(&builder, "app|lib/input.txt").unwrap(),
            vec!["app|lib/input.multi"]
        );
        assert_eq!(
            outputs_for(&builder, "app|lib/special.txt").unwrap(),
            vec!["app|lib/special.multi", "app|lib/special.generated.txt"]
        );
    }

    #[test]
    fn capture_input_outputs_replace_named_parts_and_preserve_package() {
        let builder = Arc::new(BuilderDefinition {
            id: "example:builder".to_owned(),
            kind: BuilderKind::Normal,
            extensions: vec![BuilderExtension {
                input_suffix: "assets/{{dir}}/{{file}}.txt".to_owned(),
                input_is_exact: false,
                input_is_capture: true,
                input_is_anchored: true,
                output_suffixes: vec!["lib/generated/{{dir}}/{{file}}.dart".to_owned()],
            }],
            post_process_input_extensions: Vec::new(),
            build_to: BuildTo::Source,
            phase: 0,
            output_is_optional: false,
            required_input_suffix: None,
            excluded_input_suffixes: Vec::new(),
            applies_builder: None,
        });
        assert_eq!(
            outputs_for(&builder, "app|assets/nested/input.txt").unwrap(),
            vec!["app|lib/generated/nested/input.dart"]
        );
        assert!(outputs_for(&builder, "app|other/nested/input.txt").is_err());
    }

    #[test]
    fn duplicate_outputs_are_rejected_before_execution() {
        let first = Arc::new(BuilderDefinition {
            id: "example:first".to_owned(),
            kind: BuilderKind::Normal,
            extensions: vec![BuilderExtension {
                input_suffix: "lib/input.txt".to_owned(),
                input_is_exact: true,
                input_is_capture: false,
                input_is_anchored: true,
                output_suffixes: vec!["lib/generated.txt".to_owned()],
            }],
            post_process_input_extensions: Vec::new(),
            build_to: BuildTo::Source,
            phase: 0,
            output_is_optional: false,
            required_input_suffix: None,
            excluded_input_suffixes: Vec::new(),
            applies_builder: None,
        });
        let second = Arc::new(BuilderDefinition {
            id: "example:second".to_owned(),
            ..(*first).clone()
        });
        let specs = vec![
            BuildSpec {
                builder: first,
                target: "app:app".to_owned(),
                package: "app".to_owned(),
                phase: 0,
                instance_key: "first".to_owned(),
                input: "app|lib/input.txt".to_owned(),
                outputs: vec!["app|lib/generated.txt".to_owned()],
                options: BTreeMap::new(),
            },
            BuildSpec {
                builder: second,
                target: "app:app".to_owned(),
                package: "app".to_owned(),
                phase: 0,
                instance_key: "second".to_owned(),
                input: "app|lib/input.txt".to_owned(),
                outputs: vec!["app|lib/generated.txt".to_owned()],
                options: BTreeMap::new(),
            },
        ];
        let error = validate_unique_outputs(&specs).unwrap_err();
        assert!(error.to_string().contains("builder outputs collide"));
        assert!(error.to_string().contains("app|lib/generated.txt"));
    }
}
