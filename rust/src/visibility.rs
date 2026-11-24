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
                    .insert(output.clone(), spec.instance.builder.build_to);
                match spec.instance.builder.kind {
                    BuilderKind::Normal => {
                        visibility
                            .normal_output_phases
                            .entry(spec.instance.phase)
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

        // A shared part evolves after each contributing phase. Its final
        // graph owner does not hide earlier contributions from later phases.
        let mut shared = BTreeMap::<String, u32>::new();
        for spec in specs
            .iter()
            .filter(|spec| spec.instance.builder.adds_to_library)
        {
            if let Some(id) = crate::build::shared_parts::part_id(&spec.input) {
                shared
                    .entry(id)
                    .and_modify(|phase| *phase = (*phase).min(spec.instance.phase))
                    .or_insert(spec.instance.phase);
            }
        }
        for (asset, first_phase) in shared {
            visibility.locations.insert(asset.clone(), BuildTo::Source);
            for outputs in visibility.normal_output_phases.values_mut() {
                outputs.remove(&asset);
            }
            visibility
                .normal_output_phases
                .entry(first_phase)
                .or_default()
                .insert(asset);
        }
        visibility
    }

    pub(crate) fn summary(&self) -> (usize, usize, usize) {
        let normal_phase_outputs = self.normal_output_phases.values().map(BTreeSet::len).sum();
        (
            self.locations.len(),
            normal_phase_outputs,
            self.post_process_outputs.len(),
        )
    }

    pub(crate) fn location(&self, asset: &str) -> Option<BuildTo> {
        self.locations.get(asset).copied()
    }

    pub(crate) fn generated_assets<'a>(
        &'a self,
        package: &'a str,
        pattern: &'a str,
    ) -> impl Iterator<Item = &'a String> {
        crate::workspace::glob_candidates(&self.locations, package, pattern)
            .filter(move |asset| crate::workspace::asset_matches_glob(asset, package, pattern))
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

    /// Checks that the list [`Self::blocked_assets`] would produce equals
    /// `expected`, without rebuilding the list or cloning asset strings:
    /// streams the merged, deduplicated union in sorted order and compares
    /// element by element, stopping at the first difference. The only
    /// allocations are the merge bookkeeping, proportional to the number of
    /// source sets rather than the number of assets. Lets the batch
    /// dispatcher verify a reuse candidate cheaply.
    pub(crate) fn blocked_assets_eq(
        &self,
        phase: u32,
        kind: BuilderKind,
        deleted: &BTreeSet<String>,
        expected: &[String],
    ) -> bool {
        use std::cmp::Reverse;
        use std::collections::BinaryHeap;

        let mut streams: Vec<std::collections::btree_set::Iter<'_, String>> =
            vec![deleted.iter(), self.post_process_outputs.iter()];
        if kind == BuilderKind::Normal {
            streams.extend(
                self.normal_output_phases
                    .range(phase..)
                    .map(|(_, assets)| assets.iter()),
            );
        }
        let mut heap = BinaryHeap::new();
        for (index, stream) in streams.iter_mut().enumerate() {
            if let Some(value) = stream.next() {
                heap.push(Reverse((value, index)));
            }
        }
        let mut expected = expected.iter();
        let mut last: Option<&str> = None;
        while let Some(Reverse((value, index))) = heap.pop() {
            if let Some(next) = streams[index].next() {
                heap.push(Reverse((next, index)));
            }
            if last == Some(value.as_str()) {
                continue;
            }
            last = Some(value.as_str());
            match expected.next() {
                Some(candidate) if candidate == value => {}
                _ => return false,
            }
        }
        expected.next().is_none()
    }

    pub(crate) fn is_blocked(
        &self,
        asset: &str,
        phase: u32,
        kind: BuilderKind,
        deleted: &BTreeSet<String>,
    ) -> bool {
        if crate::placeholders::is_placeholder_asset(asset)
            || deleted.contains(asset)
            || self.post_process_outputs.contains(asset)
        {
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
    use crate::plan::{BuildAction, BuildSpec, BuilderInstance};
    use std::collections::{BTreeMap, BTreeSet};
    use std::sync::Arc;

    fn spec(id: &str, phase: u32, build_to: BuildTo, output: &str) -> BuildSpec {
        Arc::new(BuildAction {
            instance: Arc::new(BuilderInstance {
                builder: Arc::new(BuilderDefinition {
                    adds_to_library: false,
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
                options: serde_json::Map::new(),
                part_directive_suffix: None,
                api_cutoff: false,
            }),
            input: "app|lib/input.txt".to_owned(),
            outputs: vec![output.to_owned()],
        })
    }

    #[test]
    fn phase_visibility_and_location_are_independent() {
        let specs = vec![
            spec("app:cache", 0, BuildTo::Cache, "app|lib/input.cache"),
            spec("app:source", 1, BuildTo::Source, "app|lib/input.source"),
        ];
        let config = RustBuildConfig {
            asset_sources: None,
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

    #[test]
    fn blocked_assets_eq_matches_the_materialized_list() {
        let specs = vec![
            spec("app:cache", 0, BuildTo::Cache, "app|lib/input.cache"),
            spec("app:source", 1, BuildTo::Source, "app|lib/input.source"),
            spec("app:late", 2, BuildTo::Source, "app|lib/late.source"),
        ];
        let config = RustBuildConfig {
            asset_sources: None,
            builders: Vec::new(),
            worker_entrypoint: None,
            manifest_signature: None,
            trigger_digest: None,
            definitions: BTreeMap::new(),
        };
        let visibility = AssetVisibility::from_specs(&specs, &GraphState::default(), &config);
        // The deleted overlay overlaps a phase output (deduplication) and
        // adds an asset of its own.
        let deleted: BTreeSet<String> = [
            "app|lib/deleted.dart".to_owned(),
            "app|lib/input.source".to_owned(),
        ]
        .into_iter()
        .collect();

        for (phase, kind) in [
            (0, BuilderKind::Normal),
            (1, BuilderKind::Normal),
            (2, BuilderKind::Normal),
            (3, BuilderKind::Normal),
            (0, BuilderKind::PostProcess),
        ] {
            let mut expected = visibility.blocked_assets(phase, kind, &deleted);
            assert!(
                visibility.blocked_assets_eq(phase, kind, &deleted, &expected),
                "exact list must match at phase {phase} {kind:?}",
            );
            let mut shortened = expected.clone();
            shortened.pop();
            assert!(
                !visibility.blocked_assets_eq(phase, kind, &deleted, &shortened),
                "missing element must not match at phase {phase} {kind:?}",
            );
            let mut extended = expected.clone();
            extended.push("app|lib/zzz.dart".to_owned());
            assert!(
                !visibility.blocked_assets_eq(phase, kind, &deleted, &extended),
                "extra element must not match at phase {phase} {kind:?}",
            );
            if let Some(first) = expected.first_mut() {
                *first = "app|lib/aaa.dart".to_owned();
                assert!(
                    !visibility.blocked_assets_eq(phase, kind, &deleted, &expected),
                    "changed element must not match at phase {phase} {kind:?}",
                );
            }
        }

        // A different deleted overlay changes the list even at the same phase.
        let expected = visibility.blocked_assets(0, BuilderKind::Normal, &deleted);
        assert!(!visibility.blocked_assets_eq(0, BuilderKind::Normal, &BTreeSet::new(), &expected));
    }
}
