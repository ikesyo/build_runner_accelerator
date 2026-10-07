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
use std::time::Instant;

/// A successful optional action that was requested while another action was
/// suspended in the resident Dart worker. The build frontend commits these
/// results together with the outer transaction.
pub struct LazyBuildResult {
    pub spec: BuildSpec,
    pub result: BuildResult,
}

/// State shared by nested optional builds within one Rust transaction.
/// Optional builds are deliberately serialized on one worker because they
/// mutate the transaction overlay and may recursively request another lazy
/// output.
pub struct LazyBuildState {
    force_keys: BTreeSet<String>,
    built_keys: BTreeSet<String>,
    building_keys: BTreeSet<String>,
    results: Vec<LazyBuildResult>,
}

impl LazyBuildState {
    pub fn new(force_keys: BTreeSet<String>) -> Self {
        Self {
            force_keys,
            built_keys: BTreeSet::new(),
            building_keys: BTreeSet::new(),
            results: Vec::new(),
        }
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
        overlay: &mut BTreeMap<String, Vec<u8>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<BuildResult> {
        let started = Instant::now();
        let id = self.next_id();
        let _wall = self.wall_span("worker_build_lazy", Some(id));
        let blocked_assets =
            visibility.blocked_assets(request.phase, build_request_kind(request), deleted_overlay);
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
                    let result = decode_build_result_frame(frame)?;
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
        overlay: &mut BTreeMap<String, Vec<u8>>,
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
        overlay: &mut BTreeMap<String, Vec<u8>>,
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
                    if visibility.is_blocked(&asset, phase, kind, deleted_overlay) {
                        continue;
                    }
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
                        return self.send_asset_error(request, &error);
                    }
                }
            }
            _ => {}
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
    fn ensure_optional_output(
        &mut self,
        workspace: &Workspace,
        asset: &str,
        overlay: &mut BTreeMap<String, Vec<u8>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        phase: u32,
        kind: BuilderKind,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        if visibility.is_blocked(asset, phase, kind, deleted_overlay) || overlay.contains_key(asset)
        {
            return Ok(());
        }
        let Some(spec) = lazy_specs
            .get(asset)
            .filter(|spec| spec.builder.kind == BuilderKind::Normal)
            .cloned()
        else {
            return Ok(());
        };
        let key = spec.action_key();
        if lazy.built_keys.contains(&key) || !lazy.force_keys.contains(&key) {
            return Ok(());
        }
        if !lazy.building_keys.insert(key.clone()) {
            return Err(io::Error::other(format!(
                "optional builder dependency cycle while reading {asset}"
            )));
        }

        for output in &spec.outputs {
            deleted_overlay.insert(output.clone());
            overlay.remove(output);
        }
        let request = BuildRequest {
            builder: spec.builder.id.clone(),
            input: spec.input.clone(),
            outputs: spec.outputs.clone(),
            options: spec.options.clone(),
            phase: spec.phase,
            instance_key: spec.instance_key.clone(),
            is_root: spec.is_root,
            post_process: false,
            triggers: spec.builder.triggers.clone(),
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
                    spec.builder.id, generated.asset
                )));
            }
            overlay.insert(generated.asset.clone(), generated.bytes.clone());
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
        lazy.results.push(LazyBuildResult { spec, result });
        Ok(())
    }
}
