use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
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
