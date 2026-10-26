use crate::builder::BuilderKind;
use crate::protocol::BuildResult;
use crate::visibility::AssetVisibility;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::io;

/// Complete Rust-side context for one worker action. The phase, kind, and
/// declared outputs drive visibility checks; `instance_key` distinguishes
/// option/target instances of the same builder.
#[derive(Clone)]
pub struct BuildRequest {
    pub part_phase_index: Option<u32>,
    pub builder: String,
    pub input: String,
    pub outputs: Vec<String>,
    pub options: serde_json::Map<String, Value>,
    pub phase: u32,
    pub instance_key: String,
    pub is_root: bool,
    pub post_process: bool,
    pub triggers: Vec<crate::builder::BuilderTrigger>,
}

pub(super) fn build_request_kind(request: &BuildRequest) -> BuilderKind {
    if request.post_process {
        BuilderKind::PostProcess
    } else {
        BuilderKind::Normal
    }
}

/// Produces the one batch-level visibility hint shared by all requests.
/// Mixed phases or normal/post-process kinds are rejected because one blocked
/// set cannot describe two visibility policies.
pub(super) fn batch_blocked_assets(
    requests: &[BuildRequest],
    visibility: &AssetVisibility,
    deleted_overlay: &BTreeSet<String>,
) -> io::Result<Vec<String>> {
    let Some(first) = requests.first() else {
        return Ok(Vec::new());
    };
    if requests
        .iter()
        .any(|request| request.phase != first.phase || request.post_process != first.post_process)
    {
        return Err(io::Error::other(
            "build batch requests must share phase and builder kind",
        ));
    }
    Ok(visibility.blocked_assets(first.phase, build_request_kind(first), deleted_overlay))
}

/// Forms the v1 JSON representation used only to report comparison size in
/// diagnostics; build responses themselves require the binary capability.
fn json_build_result_value(result: &BuildResult) -> io::Result<Value> {
    let mut value = serde_json::to_value(result).map_err(io::Error::other)?;
    let object = value.as_object_mut().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "build result did not serialize to an object",
        )
    })?;
    object.insert("v".to_owned(), json!(1));
    Ok(value)
}

/// Measures the hypothetical length-prefixed JSON frame without sending it.
pub(super) fn json_build_result_frame_size(result: &BuildResult) -> io::Result<u64> {
    let value = json_build_result_value(result)?;
    let payload = serde_json::to_vec(&value).map_err(io::Error::other)?;
    Ok((payload.len() + 4) as u64)
}

/// Measures the hypothetical batch JSON frame for diagnostic comparison only.
pub(super) fn json_build_batch_result_frame_size(
    id: u64,
    results: &[BuildResult],
) -> io::Result<u64> {
    let results = results
        .iter()
        .map(json_build_result_value)
        .collect::<io::Result<Vec<_>>>()?;
    let value = json!({
        "v": 1,
        "type": "build_batch_result",
        "id": id,
        "results": results,
    });
    let payload = serde_json::to_vec(&value).map_err(io::Error::other)?;
    Ok((payload.len() + 4) as u64)
}
