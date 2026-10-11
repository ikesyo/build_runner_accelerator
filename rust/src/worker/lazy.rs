use super::WorkerClient;
use super::asset_rpc::{batch_asset_request_context, validate_asset_request_context};
use super::client::protocol_error;
use super::request::{BuildRequest, batch_blocked_assets, build_request_kind};
use crate::builder::BuilderKind;
use crate::plan::BuildSpec;
use crate::protocol::{
    BuildResult, IncomingFrame, decode_build_batch_result_frame, decode_build_result_frame,
};
use crate::visibility::AssetVisibility;
use crate::workspace::{Workspace, glob_candidates, matches_glob};
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
    candidates.extend(
        glob_candidates(overlay, package, pattern)
            .filter(|asset| {
                asset
                    .split_once('|')
                    .is_some_and(|(pkg, path)| pkg == package && matches_glob(pattern, path))
            })
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

/// A successful optional action that was requested while another action was
/// suspended in the resident Dart worker. The build frontend commits these
/// results together with the outer transaction.
pub struct LazyBuildResult {
    pub spec: BuildSpec,
    pub result: BuildResult,
}

/// State shared by optional builds and filtered normal demand in one transaction.
/// Demand builds are deliberately serialized on one worker because they
/// mutate the transaction overlay and may recursively request another lazy
/// output.
pub struct LazyBuildState {
    force_keys: BTreeSet<String>,
    built_keys: BTreeSet<String>,
    building_keys: BTreeSet<String>,
    results: Vec<LazyBuildResult>,
    failed_demand: Option<String>,
    filtered_previous: Option<crate::graph::GraphState>,
    demanded_keys: BTreeSet<String>,
    filtered_snapshot: crate::snapshot::Snapshot,
    filtered_compatible: bool,
}

impl LazyBuildState {
    pub fn new(force_keys: BTreeSet<String>) -> Self {
        Self {
            force_keys,
            built_keys: BTreeSet::new(),
            building_keys: BTreeSet::new(),
            results: Vec::new(),
            failed_demand: None,
            filtered_previous: None,
            demanded_keys: BTreeSet::new(),
            filtered_snapshot: BTreeMap::new(),
            filtered_compatible: false,
        }
    }

    pub(crate) fn filtered(
        previous: crate::graph::GraphState,
        current: crate::snapshot::Snapshot,
        compatible: bool,
    ) -> Self {
        let mut state = Self::new(BTreeSet::new());
        state.filtered_previous = Some(previous);
        state.filtered_snapshot = current;
        state.filtered_compatible = compatible;
        state
    }

    fn asset_changed(&self, asset: &str) -> bool {
        let identity = |entry: Option<&crate::snapshot::AssetSnapshot>| {
            entry.map(|e| (e.exists, e.digest.clone()))
        };
        identity(
            self.filtered_previous
                .as_ref()
                .and_then(|s| s.assets.get(asset)),
        ) != identity(self.filtered_snapshot.get(asset))
    }

    fn update_outputs(
        &mut self,
        spec: &BuildSpec,
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted: &BTreeSet<String>,
    ) {
        if self.filtered_previous.is_none() {
            return;
        }
        for output in &spec.outputs {
            let entry = if let Some(bytes) = overlay.get(output) {
                Some(crate::snapshot::AssetSnapshot {
                    exists: true,
                    digest: crate::digest::digest_bytes(bytes),
                    size: bytes.len() as u64,
                })
            } else if deleted.contains(output) {
                Some(crate::snapshot::AssetSnapshot {
                    exists: false,
                    digest: crate::digest::digest_bytes(b"<missing>"),
                    size: 0,
                })
            } else {
                None
            };
            if let Some(entry) = entry {
                self.filtered_snapshot.insert(output.clone(), entry);
            }
        }
    }

    pub(crate) fn demanded_keys(&self) -> &BTreeSet<String> {
        &self.demanded_keys
    }

    fn record_demand_failure(&mut self, error: &io::Error) {
        if self.filtered_previous.is_some() {
            self.failed_demand.get_or_insert_with(|| error.to_string());
        }
    }

    pub(crate) fn failed_demand(&self) -> Option<&str> {
        self.failed_demand.as_deref()
    }

    pub fn take_results(&mut self) -> Vec<LazyBuildResult> {
        std::mem::take(&mut self.results)
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
        let effective_deleted;
        let deleted = if lazy.filtered_previous.is_some() {
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
        self.send(&json!({
            "v": 1,
            "type": "build",
            "id": id,
            "builder": request.builder,
            "input": request.input,
            "kind": if request.post_process { "post_process" } else { "normal" },
            "allowed_outputs": request.outputs,
            "options": request.options,
            "phase": request.phase,
            "instance_key": request.instance_key,
            "is_root": request.is_root,
            "blocked_assets": blocked_assets,
            "triggers": request.triggers,
        }))?;

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
                    } else if lazy.filtered_previous.is_some() {
                        return Err(io::Error::other(
                            "filtered demand requires single-result resolver dependency metadata",
                        ));
                    }
                    let result = decode_build_result_frame(frame)?;
                    if lazy.filtered_previous.is_some() && result.stock_inputs.is_none() {
                        return Err(io::Error::other(
                            "filtered demand requires ordered stock inputs",
                        ));
                    }
                    if lazy.filtered_previous.is_some() && result.stock_globs.is_none() {
                        return Err(io::Error::other(
                            "filtered demand requires stock glob results",
                        ));
                    }
                    self.record_json_build_result_size(&result)?;
                    if result.id != id {
                        return Err(io::Error::other("worker response id mismatch"));
                    }
                    self.metrics.build_us += started.elapsed().as_micros() as u64;
                    return Ok(result);
                }
            }
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    pub(super) fn build_batch_lazy(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<Vec<BuildResult>> {
        let started = Instant::now();
        let id = self.next_id();
        let _wall = self.wall_span("worker_batch_lazy", Some(id));
        // Lazy batches have the same visibility context as ordinary batches;
        // the nested build path still carries its own single-action hint.
        let blocked_assets = batch_blocked_assets(requests, visibility, deleted_overlay)?;
        let batch_requests = requests
            .iter()
            .enumerate()
            .map(|(index, request)| {
                json!({
                    "id": index as u64,
                    "builder": request.builder,
                    "input": request.input,
                    "kind": if request.post_process { "post_process" } else { "normal" },
                    "allowed_outputs": request.outputs,
                    "options": request.options,
                    "phase": request.phase,
                    "instance_key": request.instance_key,
                    "is_root": request.is_root,
                    "triggers": request.triggers,
                })
            })
            .collect::<Vec<_>>();
        self.send(&json!({
            "v": 1,
            "type": "build_batch",
            "id": id,
            "blocked_assets": blocked_assets,
            "requests": batch_requests,
        }))?;

        loop {
            match self.receive()? {
                IncomingFrame::Json(response) => match response.get("type").and_then(Value::as_str)
                {
                    Some("asset_request") => {
                        let (build_id, active_request) =
                            batch_asset_request_context(&response, requests)?;
                        self.handle_lazy_asset_request(
                            workspace,
                            &response,
                            overlay,
                            deleted_overlay,
                            visibility,
                            active_request,
                            build_id,
                            lazy_specs,
                            lazy,
                        )?
                    }
                    Some("build_batch_result") => {
                        return Err(io::Error::other(
                            "worker sent JSON build batch result; binary capability is required",
                        ));
                    }
                    Some("error") => return Err(protocol_error("worker error", &response)),
                    _ => return Err(protocol_error("unexpected worker message", &response)),
                },
                IncomingFrame::Binary(frame) => {
                    let _decode = self.wall_span("result_decode_validate", Some(id));
                    let decoded = decode_build_batch_result_frame(frame)?;
                    self.record_json_build_batch_result_size(decoded.id, &decoded.results)?;
                    if decoded.id != id {
                        return Err(io::Error::other("worker batch response id mismatch"));
                    }
                    self.dep_graph.extend(decoded.dep_graph);
                    let results = decoded.results;
                    if results.len() != requests.len() {
                        return Err(io::Error::other("worker batch result count mismatch"));
                    }
                    if results
                        .iter()
                        .enumerate()
                        .any(|(index, result)| result.id != index as u64)
                    {
                        return Err(io::Error::other("worker batch result id mismatch"));
                    }
                    self.metrics.build_us += started.elapsed().as_micros() as u64;
                    return Ok(results);
                }
            }
        }
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
                    .filter_map(|asset| {
                        let (asset_package, asset_path) = asset.split_once('|')?;
                        (asset_package == package && matches_glob(pattern, asset_path))
                            .then_some(asset.clone())
                    })
                    .collect::<Vec<_>>();
                for asset in candidates {
                    if lazy.filtered_previous.is_none()
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
        if operation == "find_assets" && lazy.filtered_previous.is_some() {
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
    pub(super) fn ensure_optional_output(
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
        let pending_producer = lazy.filtered_previous.is_some()
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
        if lazy.filtered_previous.is_none() && !lazy.force_keys.contains(&key) {
            return Ok(());
        }
        lazy.demanded_keys.insert(key.clone());
        if !lazy.building_keys.insert(key.clone()) {
            return Err(io::Error::other(format!(
                "optional builder dependency cycle while reading {asset}"
            )));
        }

        if lazy.filtered_previous.is_some() {
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
                lazy.building_keys.remove(&key);
                lazy.built_keys.insert(key);
                lazy.update_outputs(&spec, overlay, deleted_overlay);
                lazy.results.push(LazyBuildResult { spec, result });
                return Ok(());
            }
            let previous = lazy
                .filtered_previous
                .as_ref()
                .and_then(|state| state.actions.get(&key))
                .cloned();
            let mut needs_build = !lazy.filtered_compatible
                || previous
                    .as_ref()
                    .is_none_or(|action| action.status == "skipped_missing_input");
            if let Some(producer) = lazy_specs.get(&spec.input) {
                let previously_output = lazy
                    .filtered_previous
                    .as_ref()
                    .and_then(|state| state.actions.get(&producer.action_key()))
                    .is_some_and(|action| action.outputs.contains(&spec.input));
                if !previously_output
                    && lazy
                        .filtered_snapshot
                        .get(&spec.input)
                        .is_some_and(|s| s.exists)
                {
                    needs_build = true;
                }
            }
            if let Some(previous) = &previous {
                for output in &previous.outputs {
                    if previous.output_digests.get(output)
                        != crate::plan::output_digest(&crate::plan::output_path(
                            workspace,
                            &spec.instance.builder,
                            output,
                        )?)?
                        .as_ref()
                    {
                        needs_build = true;
                    }
                }
                if !needs_build {
                    // Like stock _computeStepAction, inspect old dependencies only
                    // until a change requires running the step. New reads are then
                    // demanded by the actual BuildStep, never by an old closure.
                    let dependencies = lazy
                        .filtered_previous
                        .as_ref()
                        .and_then(|state| state.stock_input_order.get(&key))
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
                            .filter(|asset| {
                                asset.split_once('|').is_some_and(|(package, path)| {
                                    package == glob.package && matches_glob(&glob.pattern, path)
                                })
                            })
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
                            .filtered_previous
                            .as_ref()
                            .and_then(|s| s.stock_glob_members.get(&key))
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
                                if let Some(edges) = lazy
                                    .filtered_previous
                                    .as_ref()
                                    .and_then(|s| s.resolver_dep_graph.get(&dependency))
                                {
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
                lazy.building_keys.remove(&key);
                lazy.built_keys.insert(key);
                return Ok(());
            }
        }

        for output in &spec.outputs {
            deleted_overlay.insert(output.clone());
            overlay.remove(output);
        }
        let request = BuildRequest {
            builder: spec.instance.builder.id.clone(),
            input: spec.input.clone(),
            outputs: spec.outputs.clone(),
            options: spec.instance.options.clone(),
            phase: spec.instance.phase,
            instance_key: spec.instance.instance_key.clone(),
            is_root: spec.instance.is_root,
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
        lazy.building_keys.remove(&key);
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
}
