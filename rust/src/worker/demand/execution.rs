use super::super::WorkerClient;
use super::super::asset_rpc::{FilteredAssetEvidence, validate_asset_request_context};
use super::super::client::protocol_error;
use super::super::request::{BuildRequest, build_request_kind};
use super::coordinator::DemandClaim;
use super::state::{LazyBuildResult, LazyBuildState};
use crate::builder::BuilderKind;
use crate::plan::BuildSpec;
use crate::protocol::{BuildResult, IncomingFrame, decode_build_result_frame};
use crate::visibility::AssetVisibility;
use crate::workspace::{Workspace, asset_matches_glob, glob_candidates};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::sync::Arc;
use std::time::Instant;

#[expect(
    clippy::too_many_arguments,
    reason = "Glob results use the same phase-aware transaction view as asset RPC"
)]
fn filtered_glob_members(
    workspace: &Workspace,
    package: &str,
    pattern: &str,
    overlay: &BTreeMap<String, Arc<[u8]>>,
    deleted: &BTreeSet<String>,
    visibility: &AssetVisibility,
    phase: u32,
    kind: BuilderKind,
    specs: &BTreeMap<String, BuildSpec>,
) -> io::Result<Vec<String>> {
    let mut candidates: BTreeSet<String> = workspace
        .find_assets(package, pattern)?
        .into_iter()
        .collect();
    candidates.extend(visibility.generated_assets(package, pattern).cloned());
    candidates.extend(
        glob_candidates(overlay, package, pattern)
            .filter(|asset| asset_matches_glob(asset, package, pattern))
            .cloned(),
    );
    let mut sources = Vec::new();
    let mut generated = Vec::new();
    for asset in candidates {
        if visibility.is_blocked(&asset, phase, kind, deleted) {
            continue;
        }
        if !overlay.contains_key(&asset)
            && !workspace.asset_exists_at(
                &asset,
                visibility
                    .location(&asset)
                    .unwrap_or(crate::builder::BuildTo::Source),
            )?
        {
            continue;
        }
        if specs.contains_key(&asset) {
            generated.push(asset);
        } else {
            sources.push(asset);
        }
    }
    // AssetId.compareTo uses Dart String ordering (UTF-16 code units).
    sources.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    generated.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    sources.extend(generated);
    Ok(sources)
}

enum FilteredExecution<'a> {
    Worker(&'a mut WorkerClient),
    Probe,
}

impl LazyBuildState {
    pub(crate) fn probe_filtered_roots(
        &mut self,
        workspace: &Workspace,
        roots: &[String],
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        specs: &BTreeMap<String, BuildSpec>,
    ) -> io::Result<Vec<String>> {
        let mut dirty_roots = Vec::new();
        let mut execution = FilteredExecution::Probe;
        for root in roots {
            self.filtered_mut()
                .expect("probe_filtered_roots requires filtered LazyBuildState")
                .probe_root_dirty = false;
            execution.ensure_optional_output(
                workspace,
                root,
                overlay,
                deleted_overlay,
                visibility,
                u32::MAX,
                BuilderKind::Normal,
                specs,
                self,
            )?;
            if self
                .filtered_state()
                .expect("probe_filtered_roots requires filtered LazyBuildState")
                .probe_root_dirty
            {
                dirty_roots.push(root.clone());
            }
        }
        self.filtered_mut()
            .expect("probe_filtered_roots requires filtered LazyBuildState")
            .probe_root_dirty = false;
        Ok(dirty_roots)
    }
}

impl WorkerClient {
    /// Runs one action requested by a suspended asset RPC. The Dart worker
    /// receives this as a nested `build` message and returns before the
    /// original asset request is answered.
    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    fn build_lazy(
        &mut self,
        workspace: &Workspace,
        request: &BuildRequest,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<BuildResult> {
        let started = Instant::now();
        let id = self.next_id();
        let _wall = self.wall_span("worker_build_lazy", Some(id));
        let metrics_before = self.metrics;
        let effective_deleted;
        let deleted = if lazy.is_filtered() {
            // Pending producers must still reach the demand RPC even if their
            // stale artifact is logically deleted. Keep phase blocking intact.
            effective_deleted = deleted_overlay
                .iter()
                .filter(|asset| {
                    !lazy_specs
                        .get(*asset)
                        .is_some_and(|spec| !lazy.built_keys.contains(&spec.action_key()))
                })
                .cloned()
                .collect();
            &effective_deleted
        } else {
            &*deleted_overlay
        };
        let blocked_assets =
            visibility.blocked_assets(request.phase, build_request_kind(request), deleted);
        self.send_serialized(&super::super::wire::build_wire(
            id,
            request,
            &blocked_assets,
        ))?;

        loop {
            match self.receive()? {
                IncomingFrame::Json(response) => match response.get("type").and_then(Value::as_str)
                {
                    Some("asset_request") => self.handle_lazy_asset_request(
                        workspace,
                        &response,
                        overlay,
                        deleted_overlay,
                        visibility,
                        request,
                        id,
                        lazy_specs,
                        lazy,
                    )?,
                    Some("build_result") => {
                        return Err(io::Error::other(
                            "worker sent JSON build result; binary capability is required",
                        ));
                    }
                    Some("error") => return Err(protocol_error("worker error", &response)),
                    _ => return Err(protocol_error("unexpected worker message", &response)),
                },
                IncomingFrame::Binary(frame) => {
                    if let Some(graph) = frame.metadata.get("dep_graph") {
                        let edges: BTreeMap<String, Vec<String>> =
                            serde_json::from_value(graph.clone()).map_err(io::Error::other)?;
                        self.dep_graph.extend(edges);
                    } else if lazy.is_filtered() {
                        return Err(io::Error::other(
                            "filtered demand requires single-result resolver dependency metadata",
                        ));
                    }
                    if let Some(fingerprints) = frame.metadata.get("api_fingerprints") {
                        let learned: BTreeMap<
                            String,
                            Option<crate::protocol::ApiFingerprintRecord>,
                        > = serde_json::from_value(fingerprints.clone())
                            .map_err(io::Error::other)?;
                        crate::protocol::merge_fingerprint_reports(
                            &mut self.api_fingerprints,
                            learned,
                        );
                    }
                    let result = decode_build_result_frame(frame)?;
                    if lazy.is_filtered() && result.stock_inputs.is_none() {
                        return Err(io::Error::other(
                            "filtered demand requires ordered stock inputs",
                        ));
                    }
                    if lazy.is_filtered() && result.stock_globs.is_none() {
                        return Err(io::Error::other(
                            "filtered demand requires stock glob results",
                        ));
                    }
                    self.record_json_build_result_size(&result)?;
                    if result.id != id {
                        return Err(io::Error::other("worker response id mismatch"));
                    }
                    self.metrics.build_us += started.elapsed().as_micros() as u64;
                    self.trace_metrics(&_wall, metrics_before);
                    return Ok(result);
                }
            }
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    pub(in crate::worker) fn build_batch_lazy(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<Vec<BuildResult>> {
        self.run_batch_rpc(
            "worker_batch_lazy",
            requests,
            visibility,
            deleted_overlay,
            |client, deleted_overlay, response, active_request, build_id| {
                client.handle_lazy_asset_request(
                    workspace,
                    response,
                    overlay,
                    deleted_overlay,
                    visibility,
                    active_request,
                    build_id,
                    lazy_specs,
                    lazy,
                )
            },
        )
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    fn handle_lazy_asset_request(
        &mut self,
        workspace: &Workspace,
        request: &Value,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        active_request: &BuildRequest,
        expected_build_id: u64,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        let _wall = self.wall_span("asset_rpc_lazy", None);
        validate_asset_request_context(request, active_request, expected_build_id)?;
        let operation = request
            .get("op")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let phase = active_request.phase;
        let kind = build_request_kind(active_request);
        match operation {
            "resolve_assets" => {
                // Speculative reads must not bypass demand-driven optional
                // builders or cache their previous on-disk outputs. Keep
                // this path sequential: the worker treats a failed prefetch
                // as a cache miss, and read/can_read below ensure the output
                // is rebuilt only when the resolver actually requests it.
                return self.send_asset_error(
                    request,
                    &io::Error::other("dependency prefetch disabled during lazy builds"),
                );
            }
            "read" | "can_read" => {
                if let Some(asset) = request.get("asset").and_then(Value::as_str)
                    && let Err(error) = self.ensure_optional_output(
                        workspace,
                        asset,
                        overlay,
                        deleted_overlay,
                        visibility,
                        phase,
                        kind,
                        lazy_specs,
                        lazy,
                    )
                {
                    lazy.record_demand_failure(&error);
                    return self.send_asset_error(request, &error);
                }
            }
            "find_assets" => {
                let package = request
                    .get("package")
                    .and_then(Value::as_str)
                    .unwrap_or(workspace.root_package.as_str());
                let pattern = request
                    .get("pattern")
                    .and_then(Value::as_str)
                    .unwrap_or("**");
                let candidates = glob_candidates(lazy_specs, package, pattern)
                    .filter(|asset| asset_matches_glob(asset, package, pattern))
                    .cloned()
                    .collect::<Vec<_>>();
                for asset in candidates {
                    if !lazy.is_filtered()
                        && visibility.is_blocked(&asset, phase, kind, deleted_overlay)
                    {
                        continue;
                    }
                    // Filtered demand decides deletion visibility after checking
                    // whether this asset has an unbuilt replacement producer.
                    if let Err(error) = self.ensure_optional_output(
                        workspace,
                        &asset,
                        overlay,
                        deleted_overlay,
                        visibility,
                        phase,
                        kind,
                        lazy_specs,
                        lazy,
                    ) {
                        lazy.record_demand_failure(&error);
                        return self.send_asset_error(request, &error);
                    }
                }
            }
            _ => {}
        }
        if operation == "find_assets" && lazy.is_filtered() {
            let started = Instant::now();
            let package = request
                .get("package")
                .and_then(Value::as_str)
                .unwrap_or(&workspace.root_package);
            let pattern = request
                .get("pattern")
                .and_then(Value::as_str)
                .unwrap_or("**");
            let assets = filtered_glob_members(
                workspace,
                package,
                pattern,
                overlay,
                deleted_overlay,
                visibility,
                phase,
                kind,
                lazy_specs,
            )?;
            self.metrics.find_assets_requests += 1;
            self.metrics.asset_requests += 1;
            self.metrics.find_assets_results += assets.len() as u64;
            let result = self.send(&json!({"v": 1, "type": "asset_response", "id": request["id"], "ok": true, "assets": assets}));
            self.metrics.asset_rpc_us += started.elapsed().as_micros() as u64;
            return result;
        }
        self.handle_asset_request(
            workspace,
            request,
            &*overlay,
            &*deleted_overlay,
            visibility,
            active_request,
            expected_build_id,
            Some(FilteredAssetEvidence { lazy, lazy_specs }),
        )
    }

    fn send_asset_error(&mut self, request: &Value, error: &io::Error) -> io::Result<()> {
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("asset request has no id"))?;
        self.send(&json!({
            "v": 1,
            "type": "asset_response",
            "id": id,
            "ok": false,
            "error": error.to_string(),
        }))
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    pub(in crate::worker) fn ensure_optional_output(
        &mut self,
        workspace: &Workspace,
        asset: &str,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        phase: u32,
        kind: BuilderKind,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        let mut execution = FilteredExecution::Worker(self);
        execution.ensure_optional_output(
            workspace,
            asset,
            overlay,
            deleted_overlay,
            visibility,
            phase,
            kind,
            lazy_specs,
            lazy,
        )
    }
}

impl FilteredExecution<'_> {
    #[expect(
        clippy::too_many_arguments,
        reason = "Filtered demand shares one reuse path between probe and worker execution"
    )]
    fn ensure_optional_output(
        &mut self,
        workspace: &Workspace,
        asset: &str,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        phase: u32,
        kind: BuilderKind,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        let coordinator = match self {
            Self::Worker(_) => lazy.coordinator(),
            Self::Probe => None,
        };
        let Some(coordinator) = coordinator else {
            let pending_producer = lazy.is_filtered()
                && lazy_specs
                    .get(asset)
                    .is_some_and(|spec| !lazy.built_keys.contains(&spec.action_key()));
            let blocked = if pending_producer {
                visibility.is_blocked(asset, phase, kind, &BTreeSet::new())
            } else {
                visibility.is_blocked(asset, phase, kind, deleted_overlay)
            };
            if blocked || overlay.contains_key(asset) {
                return Ok(());
            }
            let Some(spec) = lazy_specs
                .get(asset)
                .filter(|spec| spec.instance.builder.kind == BuilderKind::Normal)
                .cloned()
            else {
                return Ok(());
            };
            let key = spec.action_key();
            if lazy.built_keys.contains(&key)
                || (!lazy.is_filtered() && !lazy.force_keys.contains(&key))
            {
                return Ok(());
            }
            if !lazy.building_keys.insert(key.clone()) {
                return Err(io::Error::other(format!(
                    "optional builder dependency cycle while reading {asset}"
                )));
            }
            lazy.demanded_keys.insert(key.clone());
            lazy.building_stack.push(key.clone());
            let result = self.ensure_optional_output_body(
                workspace,
                asset,
                overlay,
                deleted_overlay,
                visibility,
                phase,
                kind,
                lazy_specs,
                lazy,
            );
            lazy.building_stack.pop();
            lazy.building_keys.remove(&key);
            return result;
        };

        let pending_producer = lazy.is_filtered()
            && lazy_specs
                .get(asset)
                .is_some_and(|spec| !lazy.built_keys.contains(&spec.action_key()));
        let blocked = if pending_producer {
            visibility.is_blocked(asset, phase, kind, &BTreeSet::new())
        } else {
            visibility.is_blocked(asset, phase, kind, deleted_overlay)
        };
        if blocked || overlay.contains_key(asset) {
            return Ok(());
        }
        let Some(spec) = lazy_specs
            .get(asset)
            .filter(|spec| spec.instance.builder.kind == BuilderKind::Normal)
            .cloned()
        else {
            return Ok(());
        };
        let key = spec.action_key();
        if lazy.built_keys.contains(&key) {
            return Ok(());
        }
        if !lazy.is_filtered() && !lazy.force_keys.contains(&key) {
            return Ok(());
        }
        if lazy.building_keys.contains(&key) {
            return Err(io::Error::other(format!(
                "filtered dependency cycle while reading {asset}"
            )));
        }
        if let Some(error) = coordinator.failure() {
            return Err(io::Error::other(error));
        }
        lazy.demanded_keys.insert(key.clone());
        let parent = lazy.building_stack.last().map(String::as_str);
        let worker = lazy
            .filtered_state()
            .and_then(|filtered| filtered.worker.as_ref())
            .expect("coordinated demand requires filtered worker context")
            .worker;
        let claim = match coordinator.claim(&key, parent, worker) {
            Ok(claim) => claim,
            Err(error) => {
                lazy.record_demand_failure(&error);
                return Err(error);
            }
        };
        let mut owner = match claim {
            DemandClaim::Complete(publication) => {
                lazy.apply_publication(&spec, &publication, overlay, deleted_overlay);
                return Ok(());
            }
            DemandClaim::Owner(owner) => Some(owner),
        };

        lazy.building_keys.insert(key.clone());
        lazy.building_stack.push(key.clone());
        let result = self.ensure_optional_output_body(
            workspace,
            asset,
            overlay,
            deleted_overlay,
            visibility,
            phase,
            kind,
            lazy_specs,
            lazy,
        );
        lazy.building_stack.pop();
        lazy.building_keys.remove(&key);
        match result {
            Ok(()) => {
                lazy.complete_action(&spec, &mut owner, overlay, deleted_overlay);
                Ok(())
            }
            Err(error) => {
                if let Some(owner) = owner.as_mut() {
                    owner.fail(error.to_string());
                }
                lazy.record_demand_failure(&error);
                Err(error)
            }
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    fn ensure_optional_output_body(
        &mut self,
        workspace: &Workspace,
        asset: &str,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        phase: u32,
        kind: BuilderKind,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        let pending_producer = lazy.is_filtered()
            && lazy_specs
                .get(asset)
                .is_some_and(|spec| !lazy.built_keys.contains(&spec.action_key()));
        let blocked = if pending_producer {
            // An obsolete action's deletion must not block its replacement
            // producer. Phase visibility still applies; completed missing
            // outputs remain blocked by the ordinary deleted overlay.
            visibility.is_blocked(asset, phase, kind, &BTreeSet::new())
        } else {
            visibility.is_blocked(asset, phase, kind, deleted_overlay)
        };
        if blocked || overlay.contains_key(asset) {
            return Ok(());
        }
        let Some(spec) = lazy_specs
            .get(asset)
            .filter(|spec| spec.instance.builder.kind == BuilderKind::Normal)
            .cloned()
        else {
            return Ok(());
        };
        let key = spec.action_key();
        if lazy.built_keys.contains(&key) {
            return Ok(());
        }
        if !lazy.is_filtered() && !lazy.force_keys.contains(&key) {
            return Ok(());
        }
        lazy.demanded_keys.insert(key.clone());

        if lazy.is_filtered() {
            // Stock computes a generated primary input before checking reuse.
            self.ensure_optional_output(
                workspace,
                &spec.input,
                overlay,
                deleted_overlay,
                visibility,
                spec.instance.phase,
                BuilderKind::Normal,
                lazy_specs,
                lazy,
            )?;
            // A probe cannot know whether a dirty generated primary will
            // exist until its producer executes. Do not classify its parent
            // from stale on-disk bytes or as skipped-missing-input.
            if lazy_specs.get(&spec.input).is_some_and(|producer| {
                lazy.filtered_state()
                    .is_some_and(|filtered| filtered.dirty_keys.contains(&producer.action_key()))
            }) {
                lazy.mark_filtered_dirty(&spec);
                return Ok(());
            }
            // Stock skips a missing generated primary before examining any
            // old secondary dependency. Such dependencies must leave demand
            // state even if their retained physical outputs still exist.
            if lazy_specs.contains_key(&spec.input)
                && (deleted_overlay.contains(&spec.input)
                    || (!overlay.contains_key(&spec.input)
                        && !workspace.asset_exists_at(
                            &spec.input,
                            visibility
                                .location(&spec.input)
                                .unwrap_or(spec.instance.builder.build_to),
                        )?))
            {
                let result = crate::build::empty_filtered_result(&spec);
                for output in &spec.outputs {
                    deleted_overlay.insert(output.clone());
                    overlay.remove(output);
                }
                lazy.built_keys.insert(key);
                lazy.update_outputs(&spec, overlay, deleted_overlay);
                lazy.results.push(LazyBuildResult { spec, result });
                return Ok(());
            }
            let (previous, mut needs_build, keep_modified_outputs) = {
                let filtered = lazy
                    .filtered_state()
                    .expect("filtered reuse check requires filtered LazyBuildState");
                let previous = filtered.previous.actions.get(&key).cloned();
                let mut needs_build = !filtered.compatible
                    || previous.as_ref().is_none_or(|action| {
                        matches!(
                            action.status.as_str(),
                            "skipped_missing_input" | "undemanded"
                        )
                    });
                if let Some(producer) = lazy_specs.get(&spec.input) {
                    let previously_output = filtered
                        .previous
                        .actions
                        .get(&producer.action_key())
                        .is_some_and(|action| action.outputs.contains(&spec.input));
                    let primary_exists = filtered
                        .snapshot_delta
                        .get(&spec.input)
                        .or_else(|| filtered.snapshot.get(&spec.input))
                        .is_some_and(|snapshot| snapshot.exists);
                    if !previously_output && primary_exists {
                        needs_build = true;
                    }
                }
                (previous, needs_build, filtered.keep_modified_outputs)
            };
            if let Some(previous) = &previous {
                for output in &previous.outputs {
                    let current = crate::plan::output_digest(&crate::plan::output_path(
                        workspace,
                        &spec.instance.builder,
                        output,
                    )?)?;
                    if current.is_none()
                        || (!keep_modified_outputs
                            && previous.output_digests.get(output) != current.as_ref())
                    {
                        needs_build = true;
                    }
                }
                if !needs_build {
                    // Like stock _computeStepAction, inspect old dependencies only
                    // until a change requires running the step. New reads are then
                    // demanded by the actual BuildStep, never by an old closure.
                    let dependencies = lazy
                        .filtered_state()
                        .and_then(|filtered| filtered.previous.stock_input_order.get(&key))
                        .ok_or_else(|| io::Error::other("ordered stock inputs are unavailable"))?
                        .clone();
                    for dependency in dependencies {
                        self.ensure_optional_output(
                            workspace,
                            &dependency,
                            overlay,
                            deleted_overlay,
                            visibility,
                            spec.instance.phase,
                            BuilderKind::Normal,
                            lazy_specs,
                            lazy,
                        )?;
                        if lazy.asset_changed(&dependency) {
                            needs_build = true;
                            break;
                        }
                    }
                }
                if !needs_build {
                    for glob in &previous.glob_reads {
                        let candidates: Vec<String> = lazy_specs
                            .keys()
                            .filter(|asset| asset_matches_glob(asset, &glob.package, &glob.pattern))
                            .cloned()
                            .collect();
                        for asset in candidates {
                            self.ensure_optional_output(
                                workspace,
                                &asset,
                                overlay,
                                deleted_overlay,
                                visibility,
                                spec.instance.phase,
                                BuilderKind::Normal,
                                lazy_specs,
                                lazy,
                            )?;
                            // A producer reached only to classify glob
                            // membership may itself need to run. The probe
                            // cannot seed this consumer as reused until that
                            // producer's actual output set is known.
                            if matches!(self, FilteredExecution::Probe)
                                && lazy_specs.get(&asset).is_some_and(|producer| {
                                    lazy.filtered_state().is_some_and(|filtered| {
                                        filtered.dirty_keys.contains(&producer.action_key())
                                    })
                                })
                            {
                                needs_build = true;
                                break;
                            }
                        }
                        if needs_build {
                            break;
                        }
                        let matched = filtered_glob_members(
                            workspace,
                            &glob.package,
                            &glob.pattern,
                            overlay,
                            deleted_overlay,
                            visibility,
                            spec.instance.phase,
                            BuilderKind::Normal,
                            lazy_specs,
                        )?;
                        let glob_key = format!("{}|{}", glob.package, glob.pattern);
                        let old = lazy
                            .filtered_state()
                            .and_then(|filtered| filtered.previous.stock_glob_members.get(&key))
                            .and_then(|globs| globs.get(&glob_key))
                            .ok_or_else(|| {
                                io::Error::other("per-action stock glob evidence is unavailable")
                            })?;
                        if old != &matched {
                            needs_build = true;
                            break;
                        }
                    }
                }
                if !needs_build {
                    // Stock evaluates resolver graphs after inputs and globs.
                    // Evaluate children before parents and accumulate changes
                    // across the full previously resolved acyclic graph.
                    for entrypoint in &previous.resolver_entrypoints {
                        let mut seen = BTreeSet::new();
                        let mut stack = vec![(entrypoint.clone(), false)];
                        let mut changed = false;
                        while let Some((dependency, expanded)) = stack.pop() {
                            if !expanded {
                                if !seen.insert(dependency.clone()) {
                                    continue;
                                }
                                stack.push((dependency.clone(), true));
                                if let Some(edges) = lazy.filtered_state().and_then(|filtered| {
                                    filtered.previous.resolver_dep_graph.get(&dependency)
                                }) {
                                    stack.extend(
                                        edges.iter().rev().map(|asset| (asset.clone(), false)),
                                    );
                                }
                                continue;
                            }
                            self.ensure_optional_output(
                                workspace,
                                &dependency,
                                overlay,
                                deleted_overlay,
                                visibility,
                                spec.instance.phase,
                                BuilderKind::Normal,
                                lazy_specs,
                                lazy,
                            )?;
                            changed |= lazy.asset_changed(&dependency);
                        }
                        if changed {
                            needs_build = true;
                            break;
                        }
                    }
                }
            }
            if !needs_build {
                // A reused producer still determines which declared siblings
                // exist. A stray on-disk file cannot turn an omitted output
                // into a readable generated input for its consumers.
                if let Some(previous) = &previous {
                    for output in &spec.outputs {
                        if !previous.outputs.contains(output) {
                            deleted_overlay.insert(output.clone());
                            overlay.remove(output);
                        }
                    }
                    lazy.update_outputs(&spec, overlay, deleted_overlay);
                }
                lazy.built_keys.insert(key);
                return Ok(());
            }
        }

        // Ordinary optional chains have the same missing-primary rule as
        // filtered demand: run the producer first, then skip an absent input.
        if !lazy.is_filtered() && lazy_specs.contains_key(&spec.input) {
            self.ensure_optional_output(
                workspace,
                &spec.input,
                overlay,
                deleted_overlay,
                visibility,
                spec.instance.phase,
                BuilderKind::Normal,
                lazy_specs,
                lazy,
            )?;
            if deleted_overlay.contains(&spec.input)
                || (!overlay.contains_key(&spec.input)
                    && !workspace.asset_exists_at(
                        &spec.input,
                        visibility
                            .location(&spec.input)
                            .unwrap_or(spec.instance.builder.build_to),
                    )?)
            {
                let result = crate::build::empty_filtered_result(&spec);
                for output in &spec.outputs {
                    deleted_overlay.insert(output.clone());
                    overlay.remove(output);
                }
                lazy.built_keys.insert(key);
                lazy.results.push(LazyBuildResult { spec, result });
                return Ok(());
            }
        }

        if matches!(self, FilteredExecution::Probe) {
            lazy.mark_filtered_dirty(&spec);
            return Ok(());
        }

        for output in &spec.outputs {
            deleted_overlay.insert(output.clone());
            overlay.remove(output);
        }
        let request = BuildRequest {
            part_phase_index: None,
            builder: spec.instance.builder.id.clone(),
            input: spec.input.clone(),
            outputs: spec.outputs.clone(),
            options: spec.instance.options.clone(),
            phase: spec.instance.phase,
            instance_key: spec.instance.instance_key.clone(),
            is_root: spec.instance.is_root,
            api_cutoff: spec.instance.api_cutoff,
            post_process: false,
            triggers: spec.instance.builder.triggers.clone(),
        };
        let result = self.build_lazy(
            workspace,
            &request,
            overlay,
            deleted_overlay,
            visibility,
            lazy_specs,
            lazy,
        );
        let result = result?;
        if result.status != "success" && result.status != "not_triggered" {
            return Err(io::Error::other(
                result
                    .error
                    .clone()
                    .unwrap_or_else(|| "Optional builder failed".to_owned()),
            ));
        }
        if !result.deleted.is_empty() {
            return Err(io::Error::other(format!(
                "deletePrimaryInput is only supported for post-process builders: {}",
                result.deleted.join(", ")
            )));
        }
        let allowed = spec.outputs.iter().cloned().collect::<BTreeSet<_>>();
        for generated in &result.outputs {
            if !allowed.contains(&generated.asset) {
                return Err(io::Error::other(format!(
                    "unexpected output from optional builder {}: {}",
                    spec.instance.builder.id, generated.asset
                )));
            }
            overlay.insert(generated.asset.clone(), Arc::clone(&generated.bytes));
            deleted_overlay.remove(&generated.asset);
        }
        let actual_outputs = result
            .outputs
            .iter()
            .map(|output| output.asset.as_str())
            .collect::<BTreeSet<_>>();
        for expected in &spec.outputs {
            if !actual_outputs.contains(expected.as_str()) {
                deleted_overlay.insert(expected.clone());
                overlay.remove(expected);
            }
        }
        lazy.built_keys.insert(key);
        lazy.update_outputs(&spec, overlay, deleted_overlay);
        lazy.results.push(LazyBuildResult { spec, result });
        Ok(())
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "Demand execution passes its shared transaction context explicitly"
    )]
    fn build_lazy(
        &mut self,
        workspace: &Workspace,
        request: &BuildRequest,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<BuildResult> {
        match self {
            Self::Worker(worker) => worker.build_lazy(
                workspace,
                request,
                overlay,
                deleted_overlay,
                visibility,
                lazy_specs,
                lazy,
            ),
            Self::Probe => Err(io::Error::other("filtered probe cannot execute a builder")),
        }
    }
}
