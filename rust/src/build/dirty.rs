use crate::builder::RustBuildConfig;
use crate::graph::{ActionState, GraphState};
use crate::metrics::FilesystemMetrics;
use crate::plan::{BuildSpec, output_digest};
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::thread;
use std::time::Instant;

use super::planning::PlannedActions;

pub(super) struct DirtyPlan {
    pub(super) dirty: Vec<BuildSpec>,
    pub(super) lazy_force_keys: BTreeSet<String>,
    pub(super) deleted_actions: Vec<(String, ActionState)>,
}

impl DirtyPlan {
    pub(super) fn has_work(&self) -> bool {
        !self.dirty.is_empty() || !self.deleted_actions.is_empty()
    }
}

pub(super) fn analyze(
    workspace: &Workspace,
    state: &GraphState,
    build_config: &RustBuildConfig,
    config_digest: &str,
    current_snapshot: &BTreeMap<String, crate::snapshot::AssetSnapshot>,
    plan: &PlannedActions,
    filesystem_metrics: &mut FilesystemMetrics,
) -> io::Result<DirtyPlan> {
    let specs = &plan.specs;
    let mut current_output_digests = BTreeMap::new();
    for action in state.actions.values() {
        if let Some(builder) = build_config.definition(&action.builder) {
            for output in &action.outputs {
                if let Some(digest) = output_digest(&workspace, builder, output)? {
                    current_output_digests.insert(output.clone(), digest);
                }
            }
        }
    }
    let mut dirty = Vec::new();
    let mut dirty_roots = Vec::new();
    let dirty_check_started = Instant::now();
    let dirty_context = state.dirty_context(&current_snapshot);
    // Reading and hashing every declared output is the bulk of the dirty
    // check; fan it out across cores before the serial evaluation loop.
    let spec_output_digests = collect_output_digests(&workspace, &specs)?;
    for (spec, digests) in specs.iter().zip(spec_output_digests) {
        current_output_digests.extend(
            digests
                .into_iter()
                .filter_map(|(output, digest)| digest.map(|digest| (output, digest))),
        );

        let key = spec.action_key();
        let needs_build = match state.actions.get(&key) {
            
            _ => true,
        };
        if needs_build {
            dirty_roots.push(spec.clone());
            if !spec.builder.is_optional {
                dirty.push(spec.clone());
            }
        }
    }
    expand_dirty_dependents(&mut dirty_roots, &specs, &state);
    let mut dirty_keys = dirty
        .iter()
        .map(|spec| spec.action_key())
        .collect::<BTreeSet<_>>();
    let mut lazy_force_keys = BTreeSet::new();
    for spec in dirty_roots {
        let key = spec.action_key();
        if spec.builder.is_optional {
            lazy_force_keys.insert(key);
        } else if dirty_keys.insert(key) {
            dirty.push(spec);
        }
    }
    filesystem_metrics.dirty_check_us = dirty_check_started.elapsed().as_micros();

    
    let deleted_actions: Vec<(String, ActionState)> = state
        .actions
        .iter()
        .filter(|(action_key, action)| {
            build_config.definition(&action.builder).is_some()
                && !expected_keys.contains(*action_key)
        })
        .map(|(key, action)| (key.clone(), action.clone()))
        .collect();
    Ok(DirtyPlan {
        dirty,
        lazy_force_keys,
        deleted_actions,
    })
}

/// Reads and digests every declared output across `specs`, returning one
/// `(output, Option<digest>)` pair list per spec in input order. The reads
/// run on a scoped thread pool because they are the bulk of the dirty check.
fn collect_output_digests(
    workspace: &Workspace,
    specs: &[crate::plan::BuildSpec],
) -> io::Result<Vec<Vec<(String, Option<String>)>>> {
    let digests_for = |spec: &crate::plan::BuildSpec| {
        spec.outputs
            .iter()
            .map(|output| {
                output_digest(workspace, &spec.builder, output)
                    .map(|digest| (output.clone(), digest))
            })
            .collect::<io::Result<Vec<_>>>()
    };
    let worker_count = thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(4)
        .min(specs.len().max(1));
    if worker_count <= 1 {
        return specs.iter().map(digests_for).collect();
    }
    let chunk_size = specs.len().div_ceil(worker_count);
    let chunks = specs.chunks(chunk_size).collect::<Vec<_>>();
    thread::scope(|scope| {
        let handles = chunks
            .iter()
            .map(|chunk| {
                scope.spawn(move || {
                    
                })
            })
            .collect::<Vec<_>>();
        handles
            .into_iter()
            .map(|handle| {
                handle
                    .join()
                    .map_err(|_| io::Error::other("output digest thread panicked"))?
            })
            .collect::<io::Result<Vec<_>>>()
            .map(|nested| nested.into_iter().flatten().collect())
    })
}

pub(super) fn expand_dirty_dependents(
    dirty: &mut Vec<crate::plan::BuildSpec>,
    specs: &[crate::plan::BuildSpec],
    state: &GraphState,
) {
    let specs_by_key = specs
        .iter()
        
        .collect::<BTreeMap<_, _>>();
    let mut dependents_by_asset = BTreeMap::<&str, Vec<&str>>::new();
    let mut actions_by_entrypoint = BTreeMap::<&str, Vec<&str>>::new();
    for (action_key, action) in &state.actions {
        for dependency in action.reads.iter().chain(action.resolver_reads.iter()) {
            dependents_by_asset
                .entry(dependency.as_str())
                .or_default()
                .push(action_key.as_str());
        }
        // Entrypoint edges stay lazy: expanding every entrypoint's closure
        // here would duplicate the whole dep graph per action. When a dirty
        // output is queried below, its ancestors in the dep graph are walked
        // once and every action entrypointed on them is invalidated.
        for entrypoint in &action.resolver_entrypoints {
            actions_by_entrypoint
                .entry(entrypoint.as_str())
                .or_default()
                .push(action_key.as_str());
        }
        // A consumer whose primary input was unavailable has no read or
        // resolver dependency to record. Preserve that edge so a producer
        // that becomes available can wake the skipped action without
        // broadening ordinary primary-input invalidation (which is already
        // handled by GraphState::changed_since_previous).
        if action.status == "skipped_missing_input" {
            dependents_by_asset
                .entry(action.input.as_str())
                .or_default()
                .push(action_key.as_str());
        }
    }
    let mut parents_by_asset = BTreeMap::<&str, Vec<&str>>::new();
    for (asset, deps) in &state.resolver_dep_graph {
        for dep in deps {
            parents_by_asset
                .entry(dep.as_str())
                .or_default()
                .push(asset.as_str());
        }
    }

    let mut dirty_keys = dirty
        .iter()
        .map(|spec| spec.action_key())
        .collect::<BTreeSet<_>>();
    let mut cursor = 0;
    while cursor < dirty.len() {
        let source_key = dirty[cursor].action_key();
        let source_outputs = match state.actions.get(&source_key) {
            Some(action) if !action.outputs.is_empty() => action.outputs.clone(),
            // Use planned outputs when the prior action did not record any:
            // a dirty producer may emit them now, so skipped consumers need a
            // chance to check whether their primary input became available.
            
                specs_by_key
                    .get(&source_key)
                    .map(|spec| spec.outputs.clone())
                    .unwrap_or_default()
            }
            Some(_) => Vec::new(),
            None => specs_by_key
                .get(&source_key)
                .map(|spec| spec.outputs.clone())
                .unwrap_or_default(),
        };
        let mut ancestors_seen = BTreeSet::<&str>::new();
        for output in &source_outputs {
            let mut dependent_keys: Vec<&str> = dependents_by_asset
                .get(output.as_str())
                .into_iter()
                .flatten()
                .copied()
                .collect();
            // Assets whose resolver dependency closure contains this output
            // are exactly its ancestors in the dep graph plus the output
            // itself. A BFS per queried output replaces per-action closure
            // expansion over the whole graph, and the seen set is shared
            // across outputs because every visited asset contributes the
            // same actions (dirty_keys deduplicates them anyway).
            let mut stack = vec![output.as_str()];
            while let Some(asset) = stack.pop() {
                if !ancestors_seen.insert(asset) {
                    continue;
                }
                dependent_keys.extend(
                    actions_by_entrypoint
                        .get(asset)
                        .into_iter()
                        .flatten()
                        .copied(),
                );
                if let Some(parents) = parents_by_asset.get(asset) {
                    stack.extend(parents.iter().copied());
                }
            }
            for dependent_key in dependent_keys {
                if dirty_keys.insert(dependent_key.to_owned()) {
                    if let Some(spec) = specs_by_key.get(dependent_key) {
                        dirty.push(spec.clone());
                    }
                }
            }
        }
        cursor += 1;
    }
}
