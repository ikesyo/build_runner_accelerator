use crate::builder::{BuildTo, BuilderKind, RustBuildConfig};
use crate::graph::GraphState;
use crate::plan::BuildSpec;
use std::collections::{BTreeMap, BTreeSet};

/// The logical asset view exposed to a worker during one build.
///
/// An asset's phase visibility and its on-disk location are independent
/// properties. A cache output can be visible to a later phase even though it
/// is never written at the package path, and a stale output can remain on
/// disk while being hidden by the transaction overlay.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct AssetVisibility {
    locations: BTreeMap<String, BuildTo>,
    normal_output_phases: BTreeMap<u32, BTreeSet<String>>,
    post_process_outputs: BTreeSet<String>,
}

impl AssetVisibility {
    /// Builds the visibility index for the current action plan and restores
    /// the physical location of post-process outputs from the previous graph.
    pub(crate) fn from_specs(
        specs: &[BuildSpec],
        state: &GraphState,
        config: &RustBuildConfig,
    ) -> Self {
        let mut visibility = Self::default();

        // The current plan is authoritative for normal outputs. State is
        // still needed for post-process outputs because those outputs are
        // dynamic and therefore do not appear in BuildSpec.outputs.
        for spec in specs {
            for output in &spec.outputs {
                visibility
                    .locations
                    .insert(output.clone(), spec.builder.build_to);
                match spec.builder.kind {
                    BuilderKind::Normal => {
                        visibility
                            .normal_output_phases
                            .entry(spec.phase)
                            .or_default()
                            .insert(output.clone());
                    }
                    BuilderKind::PostProcess => {
                        visibility.post_process_outputs.insert(output.clone());
                    }
                }
            }
        }

        for action in state.actions.values() {
            let Some(builder) = config.definition(&action.builder) else {
                continue;
            };
            for output in &action.outputs {
                // Do not overwrite a location already determined by the
                // current plan. This matters when a builder changed its
                // build_to setting and the old graph is being invalidated.
                visibility
                    .locations
                    .entry(output.clone())
                    .or_insert(builder.build_to);
                if builder.kind == BuilderKind::PostProcess {
                    visibility.post_process_outputs.insert(output.clone());
                }
            }
        }

        visibility
    }

    pub(crate) fn summary(&self) -> (usize, usize, usize) {
        let normal_phase_outputs = self
            .normal_output_phases
            .values()
            .map(BTreeSet::len)
            .sum();
        (
            self.locations.len(),
            normal_phase_outputs,
            self.post_process_outputs.len(),
        )
    }

    pub(crate) fn location(&self, asset: &str) -> Option<BuildTo> {
        self.locations.get(asset).copied()
    }

    /// Returns the logical assets hidden from an action at [phase].
    pub(crate) fn blocked_assets(
        &self,
        phase: u32,
        kind: BuilderKind,
        deleted: &BTreeSet<String>,
    ) -> Vec<String> {
        let mut blocked = deleted.clone();
        blocked.extend(self.post_process_outputs.iter().cloned());
        if kind == BuilderKind::Normal {
            for assets in self
                .normal_output_phases
                .range(phase..)
                .map(|(_, assets)| assets)
            {
                blocked.extend(assets.iter().cloned());
            }
        }
        blocked.into_iter().collect()
    }

    pub(crate) fn is_blocked(
        &self,
        asset: &str,
        phase: u32,
        kind: BuilderKind,
        deleted: &BTreeSet<String>,
    ) -> bool {
        if deleted.contains(asset) || self.post_process_outputs.contains(asset) {
            return true;
        }
        kind == BuilderKind::Normal
            && self
                .normal_output_phases
                .range(phase..)
                .any(|(_, assets)| assets.contains(asset))
    }
}

#[cfg(test)]
mod tests {
    use super::AssetVisibility;
    use crate::builder::{
        BuildTo, BuilderDefinition, BuilderExtension, BuilderKind, RustBuildConfig,
    };
    use crate::graph::GraphState;
    use crate::plan::BuildSpec;
    use std::collections::{BTreeMap, BTreeSet};
    use std::sync::Arc;

    fn spec(id: &str, phase: u32, build_to: BuildTo, output: &str) -> BuildSpec {
        BuildSpec {
            builder: Arc::new(BuilderDefinition {
                id: id.to_owned(),
                kind: BuilderKind::Normal,
                extensions: vec![BuilderExtension {
                    input_suffix: ".txt".to_owned(),
                    input_is_exact: false,
                    input_is_capture: false,
                    input_is_all: false,
                    input_is_anchored: false,
                    output_suffixes: vec![".out".to_owned()],
                }],
                post_process_input_extensions: Vec::new(),
                build_to,
                phase,
                is_optional: false,
                output_is_optional: false,
                required_input_suffixes: Vec::new(),
                excluded_input_suffixes: Vec::new(),
                applies_builder: None,
                triggers: Vec::new(),
            }),
            target: "app:app".to_owned(),
            package: "app".to_owned(),
            is_root: true,
            phase,
            instance_key: id.to_owned(),
            input: "app|lib/input.txt".to_owned(),
            outputs: vec![output.to_owned()],
            options: BTreeMap::new(),
        }
    }

    #[test]
    fn phase_visibility_and_location_are_independent() {
        let specs = vec![
            spec("app:cache", 0, BuildTo::Cache, "app|lib/input.cache"),
            spec("app:source", 1, BuildTo::Source, "app|lib/input.source"),
        ];
        let config = RustBuildConfig {
            builders: Vec::new(),
            worker_entrypoint: None,
            manifest_signature: None,
            trigger_digest: None,
            definitions: BTreeMap::new(),
        };
        let empty = BTreeSet::new();
        let visibility = AssetVisibility::from_specs(&specs, &GraphState::default(), &config);

        assert_eq!(
            visibility.location("app|lib/input.cache"),
            Some(BuildTo::Cache)
        );
        assert_eq!(
            visibility.location("app|lib/input.source"),
            Some(BuildTo::Source)
        );
        assert!(visibility.is_blocked("app|lib/input.cache", 0, BuilderKind::Normal, &empty,));
        assert!(!visibility.is_blocked("app|lib/input.cache", 1, BuilderKind::Normal, &empty,));
        assert!(visibility.is_blocked("app|lib/input.source", 1, BuilderKind::Normal, &empty,));
        assert_eq!(
            visibility.blocked_assets(0, BuilderKind::Normal, &empty),
            vec![
                "app|lib/input.cache".to_owned(),
                "app|lib/input.source".to_owned(),
            ]
        );
        assert_eq!(
            visibility.blocked_assets(1, BuilderKind::Normal, &empty),
            vec!["app|lib/input.source".to_owned()]
        );
    }
}
