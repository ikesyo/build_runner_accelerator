use crate::builder::RustBuildConfig;
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

pub(super) fn analyze(
    workspace: &Workspace,
    state: &GraphState,
    build_config: &RustBuildConfig,
    config_digest: &str,
    current_snapshot: &BTreeMap<String, crate::snapshot::AssetSnapshot>,
    plan: &PlannedActions,
    filesystem_metrics: &mut FilesystemMetrics,
) -> io::Result<DirtyPlan> {
    let dirty_check_started = Instant::now();
    let specs = &plan.specs;
    if state.actions.is_empty() {
        // No recorded action can consume a digest or contribute a dependency
        // edge: every spec is dirty, and there can be no deleted actions.
        // Still read/hash outputs once and propagate all I/O errors.
        check_unrecorded_outputs(workspace, specs, output_digest)?;
        let dirty = specs
            .iter()
            .filter(|spec| !spec.builder.is_optional)
            .cloned()
            .collect();
        let lazy_force_keys = specs
            .iter()
            .filter(|spec| spec.builder.is_optional)
            .map(BuildSpec::action_key)
            .collect();
        filesystem_metrics.dirty_check_us = dirty_check_started.elapsed().as_micros();
        return Ok(DirtyPlan {
            dirty,
            lazy_force_keys,
            deleted_actions: Vec::new(),
        });
    }
    let (recorded_output_digests, spec_output_digests) =
        collect_output_digests(workspace, state, build_config, specs, output_digest)?;
    let mut current_output_digests = BTreeMap::new();
    apply_output_digests(&mut current_output_digests, recorded_output_digests);
    let mut dirty = Vec::new();
    let mut dirty_roots = Vec::new();
    let dirty_context = state.dirty_context(current_snapshot);
    for (spec, digests) in specs.iter().zip(spec_output_digests) {
        apply_output_digests(&mut current_output_digests, digests);

        let key = spec.action_key();
        let needs_build = match state.actions.get(&key) {
            Some(action) if state.is_compatible(config_digest) => state
                .changed_since_previous_with(
                    action,
                    &dirty_context,
                    current_snapshot,
                    &current_output_digests,
                ),
            _ => true,
        };
        if needs_build {
            dirty_roots.push(spec.clone());
            if !spec.builder.is_optional {
                dirty.push(spec.clone());
            }
        }
    }
    expand_dirty_dependents(&mut dirty_roots, specs, state);
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

    let expected_keys: BTreeSet<String> = specs.iter().map(|spec| spec.action_key()).collect();
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
                .map(|output| (spec.builder.as_ref(), output.as_str())),
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
                .map(move |output| (&spec.builder, output))
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

pub(super) fn expand_dirty_dependents(
    dirty: &mut Vec<crate::plan::BuildSpec>,
    specs: &[crate::plan::BuildSpec],
    state: &GraphState,
) {
    let specs_by_key = specs
        .iter()
        .map(|spec| (spec.action_key(), spec.clone()))
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
            Some(action) if action.status == "not_triggered" || action.status == "success" => {
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
                if dirty_keys.insert(dependent_key.to_owned())
                    && let Some(spec) = specs_by_key.get(dependent_key)
                {
                    dirty.push(spec.clone());
                }
            }
        }
        cursor += 1;
    }
}
