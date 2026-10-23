use crate::builder::{BuilderKind, RustBuildConfig};
use crate::graph::{ActionState, GraphState};
use crate::metrics::FilesystemMetrics;
use crate::plan::{BuildSpec, output_digest, output_path};
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io;
use std::path::Path;
use std::sync::Mutex;
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

#[allow(clippy::too_many_arguments)]
pub(super) fn analyze(
    workspace: &Workspace,
    state: &GraphState,
    build_config: &RustBuildConfig,
    config_digest: &str,
    current_snapshot: &BTreeMap<String, crate::snapshot::AssetSnapshot>,
    plan: &PlannedActions,
    retained_outputs: &BTreeSet<String>,
    filesystem_metrics: &mut FilesystemMetrics,
) -> io::Result<DirtyPlan> {
    let dirty_check_started = Instant::now();
    let specs = &plan.specs;
    if state.actions.is_empty() {
        // No recorded action can consume a digest or contribute a dependency
        // edge: every spec is dirty, and there can be no deleted actions.
        // Still read/hash outputs once and propagate all I/O errors.
        check_unrecorded_outputs(workspace, specs, output_digest)?;
        let mut dirty = Vec::new();
        let mut lazy_force_keys = BTreeSet::new();
        for spec in specs {
            if spec.instance.builder.is_optional {
                lazy_force_keys.insert(spec.action_key());
            } else {
                dirty.push(spec.clone());
            }
        }
        filesystem_metrics.dirty_check_us = dirty_check_started.elapsed().as_micros();
        return Ok(DirtyPlan {
            dirty,
            lazy_force_keys,
            deleted_actions: Vec::new(),
        });
    }
    let (mut recorded_output_digests, mut spec_output_digests) =
        collect_output_digests(workspace, state, build_config, specs, output_digest)?;
    // The snapshot already retains logical digests for legacy kept outputs.
    // Apply the same policy to the disk digests used by output reuse checks.
    // A missing file remains missing and must still trigger its producer.
    if !retained_outputs.is_empty() {
        let retained_digests: BTreeMap<_, _> = state
            .actions
            .values()
            .flat_map(|action| &action.output_digests)
            .filter(|(asset, _)| retained_outputs.contains(*asset))
            .map(|(asset, digest)| (asset.clone(), digest.clone()))
            .collect();
        for (asset, digest) in recorded_output_digests
            .iter_mut()
            .chain(spec_output_digests.iter_mut().flatten())
        {
            if digest.is_some()
                && let Some(previous) = retained_digests.get(*asset)
            {
                *digest = Some(previous.clone());
            }
        }
    }
    let mut current_output_digests = BTreeMap::new();
    apply_output_digests(&mut current_output_digests, recorded_output_digests);
    let mut dirty = Vec::new();
    let mut dirty_roots = Vec::new();
    let dirty_context = state.dirty_context(current_snapshot);
    let compatible = state.is_compatible(config_digest);
    for (spec, digests) in specs.iter().zip(spec_output_digests) {
        let key = spec.action_key();
        // A file at a declared but previously omitted output is a conflict,
        // including after verify deliberately left it untouched. An otherwise
        // unchanged action must get a chance to remove that unexpected file.
        let has_unrecorded_output = state.actions.get(&key).is_some_and(|action| {
            digests.iter().any(|(output, digest)| {
                digest.is_some() && !action.outputs.iter().any(|actual| actual == output)
            })
        });
        apply_output_digests(&mut current_output_digests, digests);

        let needs_build = match state.actions.get(&key) {
            Some(action) if spec.instance.builder.is_optional && action.status == "undemanded" => {
                true
            }
            Some(action) if compatible => state.changed_since_previous_with(
                action,
                &dirty_context,
                current_snapshot,
                &current_output_digests,
            ),
            _ => true,
        };
        if needs_build || has_unrecorded_output {
            dirty_roots.push(spec.clone());
            if !spec.instance.builder.is_optional {
                dirty.push(spec.clone());
            }
        }
    }
    let expected_keys: BTreeSet<String> = specs.iter().map(|spec| spec.action_key()).collect();
    let deleted_actions: Vec<(String, ActionState)> = state
        .actions
        .iter()
        .filter(|(key, action)| {
            build_config.definition(&action.builder).is_some() && !expected_keys.contains(*key)
        })
        .map(|(key, action)| (key.clone(), action.clone()))
        .collect();
    let removed_outputs = deleted_actions
        .iter()
        // A changed configuration already invalidates every retained action.
        // Only compatible graphs need phase-aware removal edges; their target,
        // configured phase and builder kind still match the current manifest.
        // Never reconstruct an old target's phase from a factory definition.
        .filter(|_| compatible)
        .flat_map(|(key, action)| {
            let producer = build_config.builders.iter().find(|builder| {
                builder.definition.id == action.builder
                    && key.starts_with(&format!("{}|", builder.target))
            });
            action.outputs.iter().filter_map(move |asset| {
                producer.map(|producer| (asset.clone(), producer.phase, producer.definition.kind))
            })
        })
        .collect::<Vec<_>>();
    expand_dirty_dependents_with_removed(&mut dirty_roots, specs, state, &removed_outputs);
    let mut dirty_keys = dirty
        .iter()
        .map(|spec| spec.action_key())
        .collect::<BTreeSet<_>>();
    let mut lazy_force_keys = BTreeSet::new();
    for spec in dirty_roots {
        let key = spec.action_key();
        if spec.instance.builder.is_optional {
            lazy_force_keys.insert(key);
        } else if dirty_keys.insert(key) {
            dirty.push(spec);
        }
    }
    filesystem_metrics.dirty_check_us = dirty_check_started.elapsed().as_micros();

    Ok(DirtyPlan {
        dirty,
        lazy_force_keys,
        deleted_actions,
    })
}

type OutputDigests<'a> = Vec<(&'a str, Option<String>)>;

// Preserve the old replay order: all recorded outputs first, then each spec's
// declarations immediately before its dirty check. Missing results never erase
// a previous digest for the same logical ID (including source/cache collisions).
fn apply_output_digests(current: &mut BTreeMap<String, String>, digests: OutputDigests<'_>) {
    current.extend(
        digests
            .into_iter()
            .filter_map(|(output, digest)| digest.map(|digest| (output.to_owned(), digest))),
    );
}

/// Resolve both recorded (including dynamic/optional) and declared outputs,
/// deduplicate by physical path, and read each path once on the scoped pool.
/// The result, including NotFound, lives only for this analyze call. Logical
/// IDs and replay order are kept separately from the physical-path work list.
pub(super) fn collect_output_digests<'a>(
    workspace: &Workspace,
    state: &'a GraphState,
    build_config: &RustBuildConfig,
    specs: &'a [BuildSpec],
    digest_at_path: impl Fn(&Path) -> io::Result<Option<String>> + Sync,
) -> io::Result<(OutputDigests<'a>, Vec<OutputDigests<'a>>)> {
    let mut requests = Vec::new();
    for action in state.actions.values() {
        if let Some(builder) = build_config.definition(&action.builder) {
            requests.extend(
                action
                    .outputs
                    .iter()
                    .map(|output| (builder, output.as_str())),
            );
        }
    }
    let recorded_count = requests.len();
    for spec in specs {
        requests.extend(
            spec.outputs
                .iter()
                .map(|output| (spec.instance.builder.as_ref(), output.as_str())),
        );
    }
    // Path resolution was previously parallel with reading. Keep it parallel:
    // serial resolution/registration especially penalizes clean builds, where
    // there are no recorded outputs to share with the declarations.
    let resolved = collect_parallel(&requests, |(builder, output)| {
        output_path(workspace, builder, output)
    })?;
    let mut paths = Vec::<&Path>::new();
    let mut path_indices = HashMap::with_capacity(resolved.len());
    let indices = resolved
        .iter()
        .map(|path| {
            let next = paths.len();
            *path_indices.entry(path.as_path()).or_insert_with(|| {
                paths.push(path.as_path());
                next
            })
        })
        .collect::<Vec<_>>();
    let digests = collect_parallel(&paths, |path| digest_at_path(path))?;
    // Borrow logical IDs until a successful digest is applied. In particular,
    // clean-build misses require no logical-ID or digest string allocations.
    let mut replay = requests
        .into_iter()
        .zip(indices)
        .map(|((_, output), index)| (output, digests[index].clone()));
    let recorded = replay.by_ref().take(recorded_count).collect();
    let declared = specs
        .iter()
        .map(|spec| replay.by_ref().take(spec.outputs.len()).collect())
        .collect();
    Ok((recorded, declared))
}

/// With no recorded actions, all declarations are dirty irrespective of their
/// digests. Deduplicate the reads without building an unused replay table.
/// Only path registration is locked; path resolution, I/O and hashing run in
/// parallel. A failing read still fails the whole analysis.
pub(super) fn check_unrecorded_outputs(
    workspace: &Workspace,
    specs: &[BuildSpec],
    digest_at_path: impl Fn(&Path) -> io::Result<Option<String>> + Sync,
) -> io::Result<()> {
    let requests = specs
        .iter()
        .flat_map(|spec| {
            spec.outputs
                .iter()
                .map(move |output| (&spec.instance.builder, output))
        })
        .collect::<Vec<_>>();
    let seen = Mutex::new(HashSet::with_capacity(requests.len()));
    collect_parallel(&requests, |(builder, output)| {
        let path = output_path(workspace, builder, output)?;
        let first = seen
            .lock()
            .map_err(|_| io::Error::other("output path mutex poisoned"))?
            .insert(path.clone());
        if first {
            digest_at_path(&path)?;
        }
        Ok(())
    })?;
    Ok(())
}

fn collect_parallel<T: Sync, R: Send>(
    inputs: &[T],
    operation: impl Fn(&T) -> io::Result<R> + Sync,
) -> io::Result<Vec<R>> {
    let worker_count = thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(4)
        .min(inputs.len().max(1));
    if worker_count <= 1 {
        return inputs.iter().map(operation).collect();
    }
    let chunk_size = inputs.len().div_ceil(worker_count);
    thread::scope(|scope| {
        let handles = inputs
            .chunks(chunk_size)
            .map(|chunk| {
                let operation = &operation;
                scope.spawn(move || chunk.iter().map(operation).collect::<io::Result<Vec<_>>>())
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

/// Follow primary and recorded read dependencies from dirty normal roots.
/// Undemanded producers remain forceable, but cleanup alone cannot make their
/// possible outputs dirty work. Actual new reads are handled during execution.
fn required_by_dirty_normal(
    dirty: &[BuildSpec],
    specs: &[BuildSpec],
    state: &GraphState,
) -> BTreeSet<String> {
    let mut pending = dirty
        .iter()
        .filter(|spec| {
            spec.instance.builder.kind == BuilderKind::Normal && !spec.instance.builder.is_optional
        })
        .cloned()
        .collect::<Vec<_>>();
    if pending.is_empty() {
        return BTreeSet::new();
    }
    let producers = specs
        .iter()
        .flat_map(|spec| spec.outputs.iter().map(move |asset| (asset.as_str(), spec)))
        .collect::<BTreeMap<_, _>>();
    let mut required = BTreeSet::new();
    let mut visited_assets = BTreeSet::new();
    while let Some(spec) = pending.pop() {
        let key = spec.action_key();
        if !required.insert(key.clone()) {
            continue;
        }
        let mut assets = vec![spec.input.clone()];
        if let Some(action) = state.actions.get(&key) {
            assets.extend(
                action
                    .reads
                    .iter()
                    .chain(&action.resolver_reads)
                    .chain(&action.resolver_entrypoints)
                    .cloned(),
            );
        }
        while let Some(asset) = assets.pop() {
            if !visited_assets.insert(asset.clone()) {
                continue;
            }
            if let Some(producer) = producers.get(asset.as_str()) {
                pending.push((*producer).clone());
            }
            if let Some(dependencies) = state.resolver_dep_graph.get(&asset) {
                assets.extend(dependencies.iter().cloned());
            }
        }
    }
    required
}

#[cfg(test)]
pub(super) fn expand_dirty_dependents(
    dirty: &mut Vec<crate::plan::BuildSpec>,
    specs: &[crate::plan::BuildSpec],
    state: &GraphState,
) {
    expand_dirty_dependents_with_removed(dirty, specs, state, &[]);
}

pub(super) fn expand_dirty_dependents_with_removed(
    dirty: &mut Vec<crate::plan::BuildSpec>,
    specs: &[crate::plan::BuildSpec],
    state: &GraphState,
    removed_outputs: &[(String, u32, BuilderKind)],
) {
    let specs_by_key = specs
        .iter()
        .map(|spec| (spec.action_key(), spec))
        .collect::<BTreeMap<_, _>>();
    let mut dependents_by_asset = BTreeMap::<&str, Vec<&str>>::new();
    let mut actions_by_entrypoint = BTreeMap::<&str, Vec<&str>>::new();
    let mut glob_dependents = Vec::new();
    for (action_key, action) in &state.actions {
        if let Some(spec) = specs_by_key.get(action_key) {
            for glob in &action.glob_reads {
                glob_dependents.push((action_key.as_str(), spec.instance.phase, glob));
            }
        }
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

    let required = if dirty.iter().any(|spec| {
        state
            .actions
            .get(&spec.action_key())
            .is_some_and(|action| action.status == "undemanded")
    }) {
        required_by_dirty_normal(dirty, specs, state)
    } else {
        BTreeSet::new()
    };
    let mut dirty_keys = dirty
        .iter()
        .map(|spec| spec.action_key())
        .collect::<BTreeSet<_>>();
    let mut cursor = 0;
    let mut removed_cursor = 0;
    while cursor < dirty.len() || removed_cursor < removed_outputs.len() {
        let (source_outputs, source_phase, source_kind, removed) = if cursor < dirty.len() {
            let source_key = dirty[cursor].action_key();
            let source_outputs = match state.actions.get(&source_key) {
                Some(action)
                    if action.status == "undemanded" && !required.contains(&source_key) =>
                {
                    Vec::new()
                }
                Some(action) if !action.outputs.is_empty() => action
                    .outputs
                    .iter()
                    .cloned()
                    .chain(
                        specs_by_key
                            .get(&source_key)
                            .into_iter()
                            .flat_map(|spec| spec.outputs.iter().cloned()),
                    )
                    .collect::<BTreeSet<_>>()
                    .into_iter()
                    .collect(),
                // Use planned outputs when the prior action did not record any:
                // a dirty producer may emit them now, so skipped consumers need a
                // chance to check whether their primary input became available.
                Some(action)
                    if matches!(
                        action.status.as_str(),
                        "not_triggered" | "success" | "undemanded"
                    ) =>
                {
                    specs_by_key
                        .get(&source_key)
                        .map(|spec| spec.outputs.clone())
                        .unwrap_or_default()
                }
                // Missing-primary-input actions are also committed after an
                // otherwise successful build, so this arm remains reachable.
                Some(_) => Vec::new(),
                None => specs_by_key
                    .get(&source_key)
                    .map(|spec| spec.outputs.clone())
                    .unwrap_or_default(),
            };
            let source = &dirty[cursor];
            let result = (
                source_outputs,
                source.instance.phase,
                source.instance.builder.kind,
                false,
            );
            cursor += 1;
            result
        } else {
            let (asset, phase, kind) = &removed_outputs[removed_cursor];
            removed_cursor += 1;
            (vec![asset.clone()], *phase, *kind, true)
        };
        let mut ancestors_seen = BTreeSet::<&str>::new();
        for output in &source_outputs {
            let mut dependent_keys: Vec<&str> = dependents_by_asset
                .get(output.as_str())
                .into_iter()
                .flatten()
                .copied()
                .collect();
            // Globs observe earlier-phase generated candidates, including new
            // optional outputs and removed producers whose cache bytes remain.
            // A recorded content read cannot represent a new glob member.
            if source_kind == BuilderKind::Normal {
                dependent_keys.extend(glob_dependents.iter().filter_map(|(key, phase, glob)| {
                    (source_phase < *phase
                        && output.split_once('|').is_some_and(|(package, path)| {
                            package == glob.package
                                && crate::workspace::matches_glob(&glob.pattern, path)
                        }))
                    .then_some(*key)
                }));
            }
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
                let Some(spec) = specs_by_key.get(dependent_key) else {
                    continue;
                };
                // Do not turn removed hidden outputs into new invalidation
                // edges. Preserve ordinary dirty-producer propagation: its
                // resolver evidence can conservatively include future parts.
                let visible = !removed
                    || spec.instance.builder.kind == BuilderKind::PostProcess
                    || (source_kind == BuilderKind::Normal && source_phase < spec.instance.phase);
                if visible && dirty_keys.insert(dependent_key.to_owned()) {
                    dirty.push((*spec).clone());
                }
            }
        }
    }
}
