use super::request::{BuildRequest, batch_blocked_assets, batch_context};
use crate::protocol::write_frame_buffered;
use crate::visibility::AssetVisibility;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io;

/// One unit's answer to an ADR 0056 preflight query. Either field is
/// `None` when the worker could not produce it for the unit's current
/// content; the frontend treats missing evidence as content-keyed.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ApiUnitEvidence {
    pub fingerprint: Option<String>,
    pub deps: Option<Vec<String>>,
}

/// Decodes one unit's preflight answer. The wire shape is `null`
/// (unavailable) or an object whose `fingerprint` is a string or
/// null and whose `deps` is an array of strings or null. Anything
/// else is malformed, and malformed evidence is discarded whole:
/// a silently truncated dependency list could otherwise pass as an
/// unchanged one and waive an action on fabricated evidence.
pub(super) fn decode_api_unit_evidence(value: &Value) -> ApiUnitEvidence {
    let malformed = ApiUnitEvidence::default();
    if value.is_null() {
        return malformed;
    }
    let Some(object) = value.as_object() else {
        return malformed;
    };
    let fingerprint = match object.get("fingerprint") {
        Some(Value::Null) | None => None,
        Some(Value::String(fingerprint)) => Some(fingerprint.clone()),
        Some(_) => return malformed,
    };
    let deps = match object.get("deps") {
        Some(Value::Null) | None => None,
        Some(Value::Array(items)) => {
            let mut deps = Vec::with_capacity(items.len());
            for item in items {
                let Some(dep) = item.as_str() else {
                    return malformed;
                };
                deps.push(dep.to_owned());
            }
            Some(deps)
        }
        Some(_) => return malformed,
    };
    ApiUnitEvidence { fingerprint, deps }
}

/// Transport state belongs to one worker connection. Resets and single builds
/// do not replace the last batch list; initialization starts a fresh context.
#[derive(Default)]
pub(super) struct BlockedAssetsCache {
    pub(super) capable: bool,
    last: Option<Vec<String>>,
}

impl BlockedAssetsCache {
    pub(super) fn new(capable: bool) -> Self {
        Self {
            capable,
            last: None,
        }
    }

    pub(super) fn forget_last(&mut self) {
        self.last = None;
    }

    /// Decides the visibility hint for one batch. When the candidate equals
    /// the list last sent on this connection, the equality is verified
    /// against the cached list without rebuilding the candidate
    /// ([`AssetVisibility::blocked_assets_eq`]) and the reuse form is sent.
    pub(super) fn prepare(
        &mut self,
        requests: &[BuildRequest],
        visibility: &AssetVisibility,
        deleted_overlay: &BTreeSet<String>,
    ) -> io::Result<(Vec<String>, bool)> {
        let Some((phase, kind)) = batch_context(requests)? else {
            return Ok(self.prepare_list(Vec::new()));
        };
        let reuse = self.capable
            && self.last.as_ref().is_some_and(|last| {
                visibility.blocked_assets_eq(phase, kind, deleted_overlay, last)
            });
        if reuse {
            return Ok((Vec::new(), true));
        }
        let assets = batch_blocked_assets(requests, visibility, deleted_overlay)?;
        Ok(self.prepare_list(assets))
    }

    pub(super) fn prepare_list(&mut self, assets: Vec<String>) -> (Vec<String>, bool) {
        if !self.capable {
            return (assets, false);
        }
        if self.last.as_ref() == Some(&assets) {
            return (Vec::new(), true);
        }
        self.last = Some(assets.clone());
        (assets, false)
    }
}

/// Serde skip predicate for fields that are only sent when set: an
/// absent `api_cutoff` decodes as false on the worker.
fn is_false(value: &bool) -> bool {
    !*value
}

/// Encodes asset identifiers into wire representation: borrowed strings for
/// plain frames, or per-connection dictionary indexes for `asset-id-interning-v1`.
pub(super) trait AssetIdCodec {
    type Id<'a>: serde::Serialize;
    type IdList<'a>: serde::Serialize;

    fn encode_id<'a>(&mut self, asset: &'a str) -> Self::Id<'a>;
    fn encode_list<'a>(&mut self, assets: &'a [String]) -> Self::IdList<'a>;
    fn encode_digest_key(&mut self, asset: &str) -> String;
    fn take_dict_additions(&mut self) -> Option<Vec<String>>;
}

pub(super) struct PlainAssetIds;

impl AssetIdCodec for PlainAssetIds {
    type Id<'a> = &'a str;
    type IdList<'a> = &'a [String];

    fn encode_id<'a>(&mut self, asset: &'a str) -> &'a str {
        asset
    }

    fn encode_list<'a>(&mut self, assets: &'a [String]) -> &'a [String] {
        assets
    }

    fn encode_digest_key(&mut self, asset: &str) -> String {
        asset.to_owned()
    }

    fn take_dict_additions(&mut self) -> Option<Vec<String>> {
        None
    }
}

/// Assigns dictionary indexes for one outgoing message, recording the ids
/// the message introduces so they can be sent as its `asset_dict_add` list.
/// The client dictionary grows as messages are encoded. If the send itself
/// fails, the caller rolls the dictionary back to its pre-message length
/// with [`rollback_asset_dictionary`], because the worker never received
/// the additions; once the frame is written, the worker applies the same
/// additions while decoding and they are never rolled back. See ADR 0053.
pub(super) struct AssetInterner<'a> {
    dictionary: &'a mut Vec<String>,
    index: &'a mut HashMap<String, u32>,
    pub(super) additions: Vec<String>,
}

impl AssetInterner<'_> {
    pub(super) fn new<'a>(
        dictionary: &'a mut Vec<String>,
        index: &'a mut HashMap<String, u32>,
    ) -> AssetInterner<'a> {
        AssetInterner {
            dictionary,
            index,
            additions: Vec::new(),
        }
    }

    pub(super) fn intern(&mut self, asset: &str) -> u32 {
        if let Some(&existing) = self.index.get(asset) {
            return existing;
        }
        let fresh = self.dictionary.len() as u32;
        self.dictionary.push(asset.to_owned());
        self.index.insert(asset.to_owned(), fresh);
        self.additions.push(asset.to_owned());
        fresh
    }

    pub(super) fn intern_list(&mut self, assets: &[String]) -> Vec<u32> {
        assets.iter().map(|asset| self.intern(asset)).collect()
    }
}

impl AssetIdCodec for AssetInterner<'_> {
    type Id<'a> = u32;
    type IdList<'a> = Vec<u32>;

    fn encode_id(&mut self, asset: &str) -> u32 {
        self.intern(asset)
    }

    fn encode_list(&mut self, assets: &[String]) -> Vec<u32> {
        self.intern_list(assets)
    }

    fn encode_digest_key(&mut self, asset: &str) -> String {
        self.intern(asset).to_string()
    }

    fn take_dict_additions(&mut self) -> Option<Vec<String>> {
        Some(std::mem::take(&mut self.additions))
    }
}

/// One build request in a batch, serialized directly from the borrowed
/// [`BuildRequest`] fields instead of an intermediate JSON value tree.
/// Field order matches the JSON shape the worker has always received;
/// telemetry fields appear only while a telemetry context is active.
#[derive(serde::Serialize)]
pub(super) struct BatchRequestWire<'a, I, O> {
    id: u64,
    builder: &'a str,
    input: I,
    kind: &'a str,
    allowed_outputs: O,
    options: &'a serde_json::Map<String, Value>,
    phase: u32,
    part_phase_index: Option<u32>,
    instance_key: &'a str,
    is_root: bool,
    #[serde(skip_serializing_if = "is_false")]
    api_cutoff: bool,
    triggers: &'a [crate::builder::BuilderTrigger],
    #[serde(skip_serializing_if = "Option::is_none")]
    traceparent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    otel_report_id: Option<u64>,
}

/// Batch-level fields shared by every request in a batch, sent once under
/// `shared` when the worker advertises `batch-shared-fields-v1` and the
/// batch is uniform in them. The worker merges them into each child
/// request before decoding it; see ADR 0052.
#[derive(serde::Serialize)]
pub(super) struct BatchSharedWire<'a> {
    builder: &'a str,
    phase: u32,
    kind: &'a str,
    part_phase_index: Option<u32>,
    instance_key: &'a str,
    is_root: bool,
    #[serde(skip_serializing_if = "is_false")]
    api_cutoff: bool,
}

/// A batch request in shared-fields form: the fields that
/// [`BatchSharedWire`] does not carry. See [`BatchRequestWire`].
#[derive(serde::Serialize)]
pub(super) struct BatchSharedRequestWire<'a, I, O> {
    id: u64,
    input: I,
    allowed_outputs: O,
    options: &'a serde_json::Map<String, Value>,
    triggers: &'a [crate::builder::BuilderTrigger],
    #[serde(skip_serializing_if = "Option::is_none")]
    traceparent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    otel_report_id: Option<u64>,
}

/// The `build_batch` envelope. When `asset_dict_add` is `Some`, the frame is
/// interned (ADR 0053) and every asset id position carries a dictionary index;
/// when `None`, the key is omitted and plain asset ids are sent.
/// See [`BatchRequestWire`].
#[derive(serde::Serialize)]
pub(super) struct BatchWire<'a, B, R> {
    pub(super) v: u32,
    #[serde(rename = "type")]
    pub(super) message_type: &'a str,
    pub(super) id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) asset_dict_add: Option<Vec<String>>,
    pub(super) blocked_assets: B,
    pub(super) blocked_assets_reuse: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) shared: Option<BatchSharedWire<'a>>,
    /// `asset-digests-v1` delta keyed by asset id (plain) or decimal
    /// dictionary index (interned); a null value removes the id from the
    /// worker's digest map. See ADR 0054.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) asset_digests: Option<BTreeMap<String, Option<String>>>,
    pub(super) requests: &'a [R],
}

/// The single `build` envelope used by the lazy/nested path, carrying its
/// own visibility hint. See [`BatchRequestWire`].
#[derive(serde::Serialize)]
pub(super) struct BuildWire<'a> {
    pub(super) v: u32,
    #[serde(rename = "type")]
    pub(super) message_type: &'a str,
    pub(super) id: u64,
    pub(super) builder: &'a str,
    pub(super) input: &'a str,
    pub(super) kind: &'a str,
    pub(super) allowed_outputs: &'a [String],
    pub(super) options: &'a serde_json::Map<String, Value>,
    pub(super) phase: u32,
    pub(super) part_phase_index: Option<u32>,
    pub(super) instance_key: &'a str,
    pub(super) is_root: bool,
    #[serde(skip_serializing_if = "is_false")]
    pub(super) api_cutoff: bool,
    pub(super) blocked_assets: &'a [String],
    pub(super) triggers: &'a [crate::builder::BuilderTrigger],
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) traceparent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) otel_report_id: Option<u64>,
}

/// The `asset-digests-v1` delta between the digests a connection has
/// already sent and the current build's staged map: updates and removals
/// (as `None`) keyed by asset id. Empty when the capability is off,
/// nothing is staged, or the worker is already current. See ADR 0054.
pub(super) fn compute_asset_digest_delta(
    capable: bool,
    sent: &HashMap<String, String>,
    staged: Option<&BTreeMap<String, String>>,
) -> Vec<(String, Option<String>)> {
    if !capable {
        return Vec::new();
    }
    let Some(staged) = staged else {
        return Vec::new();
    };
    let mut delta = Vec::new();
    for (asset, digest) in staged {
        if sent.get(asset) != Some(digest) {
            delta.push((asset.clone(), Some(digest.clone())));
        }
    }
    for asset in sent.keys() {
        if !staged.contains_key(asset) {
            delta.push((asset.clone(), None));
        }
    }
    delta
}

/// Undoes every dictionary addition at or after `checkpoint`, the
/// dictionary length before a message whose send failed. Additions are
/// always a suffix of the dictionary, so truncating and dropping their
/// index entries restores the exact pre-message state.
pub(super) fn rollback_asset_dictionary(
    dictionary: &mut Vec<String>,
    index: &mut HashMap<String, u32>,
    checkpoint: usize,
) {
    for asset in &dictionary[checkpoint..] {
        index.remove(asset);
    }
    dictionary.truncate(checkpoint);
}

/// Rewrites a JSON array of asset ids as dictionary indexes. Elements that
/// are not strings pass through unchanged; the worker rejects them when it
/// decodes the interned message, as it would any malformed list.
pub(super) fn intern_asset_list(value: &Value, interner: &mut AssetInterner<'_>) -> Value {
    match value {
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|item| match item {
                    Value::String(asset) => Value::from(interner.intern(asset)),
                    other => other.clone(),
                })
                .collect(),
        ),
        other => other.clone(),
    }
}

/// Rewrites the overlay blob descriptor's `index` keys as decimal
/// dictionary indexes; JSON object keys cannot be integers. The descriptor
/// itself and its offsets/lengths are unchanged.
pub(super) fn intern_overlay_blob(value: &Value, interner: &mut AssetInterner<'_>) -> Value {
    let Some(map) = value.as_object() else {
        return value.clone();
    };
    let mut map = map.clone();
    if let Some(index) = map.get("index").and_then(Value::as_object) {
        let interned = index
            .iter()
            .map(|(asset, entry)| (interner.intern(asset).to_string(), entry.clone()))
            .collect::<serde_json::Map<String, Value>>();
        map.insert("index".to_owned(), Value::Object(interned));
    }
    Value::Object(map)
}

/// Per-request telemetry fields: one message-level context, consumed by
/// the first request; later requests draw fresh contexts. All `None` when
/// no session is active.
fn telemetry_contexts_with(
    count: usize,
    mut provider: impl FnMut() -> Option<(String, u64)>,
) -> Vec<(Option<String>, Option<u64>)> {
    let mut first_context = provider();
    let inject = first_context.is_some();
    (0..count)
        .map(|_| {
            if inject {
                match first_context.take().or_else(&mut provider) {
                    Some((parent, report_id)) => (Some(parent), Some(report_id)),
                    None => (None, None),
                }
            } else {
                (None, None)
            }
        })
        .collect()
}

pub(super) fn batch_request_wires<'a, C: AssetIdCodec>(
    requests: &'a [BuildRequest],
    codec: &mut C,
) -> Vec<BatchRequestWire<'a, C::Id<'a>, C::IdList<'a>>> {
    batch_request_wires_with(requests, codec, crate::telemetry::request_context)
}

pub(super) fn batch_request_wires_with<'a, C: AssetIdCodec>(
    requests: &'a [BuildRequest],
    codec: &mut C,
    provider: impl FnMut() -> Option<(String, u64)>,
) -> Vec<BatchRequestWire<'a, C::Id<'a>, C::IdList<'a>>> {
    let contexts = telemetry_contexts_with(requests.len(), provider);
    requests
        .iter()
        .enumerate()
        .zip(contexts)
        .map(
            |((index, request), (traceparent, otel_report_id))| BatchRequestWire {
                id: index as u64,
                builder: &request.builder,
                input: codec.encode_id(&request.input),
                kind: if request.post_process {
                    "post_process"
                } else {
                    "normal"
                },
                allowed_outputs: codec.encode_list(&request.outputs),
                options: &request.options,
                phase: request.phase,
                part_phase_index: request.part_phase_index,
                instance_key: &request.instance_key,
                is_root: request.is_root,
                api_cutoff: request.api_cutoff,
                triggers: &request.triggers,
                traceparent,
                otel_report_id,
            },
        )
        .collect()
}

pub(super) fn batch_shared_request_wires<'a, C: AssetIdCodec>(
    requests: &'a [BuildRequest],
    codec: &mut C,
) -> Vec<BatchSharedRequestWire<'a, C::Id<'a>, C::IdList<'a>>> {
    batch_shared_request_wires_with(requests, codec, crate::telemetry::request_context)
}

pub(super) fn batch_shared_request_wires_with<'a, C: AssetIdCodec>(
    requests: &'a [BuildRequest],
    codec: &mut C,
    provider: impl FnMut() -> Option<(String, u64)>,
) -> Vec<BatchSharedRequestWire<'a, C::Id<'a>, C::IdList<'a>>> {
    let contexts = telemetry_contexts_with(requests.len(), provider);
    requests
        .iter()
        .enumerate()
        .zip(contexts)
        .map(
            |((index, request), (traceparent, otel_report_id))| BatchSharedRequestWire {
                id: index as u64,
                input: codec.encode_id(&request.input),
                allowed_outputs: codec.encode_list(&request.outputs),
                options: &request.options,
                triggers: &request.triggers,
                traceparent,
                otel_report_id,
            },
        )
        .collect()
}

/// The shared-fields form of a batch, when every request agrees on the
/// fields it lifts. Single-request batches keep the full form: there is
/// nothing to deduplicate.
pub(super) fn batch_shared_fields(requests: &[BuildRequest]) -> Option<BatchSharedWire<'_>> {
    let first = requests.first()?;
    if requests.len() < 2 {
        return None;
    }
    let uniform = requests.iter().all(|request| {
        request.builder == first.builder
            && request.phase == first.phase
            && request.post_process == first.post_process
            && request.part_phase_index == first.part_phase_index
            && request.instance_key == first.instance_key
            && request.is_root == first.is_root
            && request.api_cutoff == first.api_cutoff
    });
    uniform.then(|| BatchSharedWire {
        builder: &first.builder,
        phase: first.phase,
        kind: if first.post_process {
            "post_process"
        } else {
            "normal"
        },
        part_phase_index: first.part_phase_index,
        instance_key: &first.instance_key,
        is_root: first.is_root,
        api_cutoff: first.api_cutoff,
    })
}

pub(super) fn build_wire<'a>(
    id: u64,
    request: &'a BuildRequest,
    blocked_assets: &'a [String],
) -> BuildWire<'a> {
    let (traceparent, otel_report_id) = match crate::telemetry::request_context() {
        Some((parent, report_id)) => (Some(parent), Some(report_id)),
        None => (None, None),
    };
    BuildWire {
        v: 1,
        message_type: "build",
        id,
        builder: &request.builder,
        input: &request.input,
        kind: if request.post_process {
            "post_process"
        } else {
            "normal"
        },
        allowed_outputs: &request.outputs,
        options: &request.options,
        phase: request.phase,
        part_phase_index: request.part_phase_index,
        instance_key: &request.instance_key,
        is_root: request.is_root,
        api_cutoff: request.api_cutoff,
        blocked_assets,
        triggers: &request.triggers,
        traceparent,
        otel_report_id,
    }
}

#[expect(clippy::too_many_arguments)]
pub(super) fn write_batch_frame<W: io::Write, C: AssetIdCodec>(
    writer: &mut W,
    buffer: &mut Vec<u8>,
    id: u64,
    requests: &[BuildRequest],
    blocked_assets: &[String],
    blocked_assets_reuse: bool,
    digest_delta: &[(String, Option<String>)],
    shared: Option<BatchSharedWire<'_>>,
    codec: &mut C,
) -> io::Result<usize> {
    // Preserve exact interning order: blocked_assets -> asset_digests -> requests.
    let blocked = codec.encode_list(blocked_assets);
    let asset_digests = (!digest_delta.is_empty()).then(|| {
        digest_delta
            .iter()
            .map(|(asset, digest)| (codec.encode_digest_key(asset), digest.clone()))
            .collect::<BTreeMap<_, _>>()
    });
    if let Some(shared) = shared {
        let wires = batch_shared_request_wires(requests, codec);
        write_batch_envelope(
            writer,
            buffer,
            id,
            codec.take_dict_additions(),
            blocked,
            blocked_assets_reuse,
            Some(shared),
            asset_digests,
            &wires,
        )
    } else {
        let wires = batch_request_wires(requests, codec);
        write_batch_envelope(
            writer,
            buffer,
            id,
            codec.take_dict_additions(),
            blocked,
            blocked_assets_reuse,
            None,
            asset_digests,
            &wires,
        )
    }
}

#[expect(clippy::too_many_arguments)]
fn write_batch_envelope<W: io::Write, B: serde::Serialize, R: serde::Serialize>(
    writer: &mut W,
    buffer: &mut Vec<u8>,
    id: u64,
    asset_dict_add: Option<Vec<String>>,
    blocked_assets: B,
    blocked_assets_reuse: bool,
    shared: Option<BatchSharedWire<'_>>,
    asset_digests: Option<BTreeMap<String, Option<String>>>,
    requests: &[R],
) -> io::Result<usize> {
    let wire = BatchWire {
        v: 1,
        message_type: "build_batch",
        id,
        asset_dict_add,
        blocked_assets,
        blocked_assets_reuse,
        shared,
        asset_digests,
        requests,
    };
    write_frame_buffered(writer, &wire, buffer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn api_unit_evidence_discards_malformed_replies() {
        assert_eq!(
            decode_api_unit_evidence(&json!({"fingerprint": "fp", "deps": ["a", "b"]})),
            ApiUnitEvidence {
                fingerprint: Some("fp".into()),
                deps: Some(vec!["a".into(), "b".into()]),
            }
        );
        assert_eq!(
            decode_api_unit_evidence(&json!({"fingerprint": null, "deps": null})),
            ApiUnitEvidence::default()
        );
        assert_eq!(
            decode_api_unit_evidence(&json!(null)),
            ApiUnitEvidence::default()
        );
        // A non-string dep must not be dropped silently: the whole
        // answer is discarded, so it cannot pass as complete.
        assert_eq!(
            decode_api_unit_evidence(&json!({"fingerprint": "fp", "deps": ["a", 1]})),
            ApiUnitEvidence::default()
        );
        assert_eq!(
            decode_api_unit_evidence(&json!({"fingerprint": 1, "deps": []})),
            ApiUnitEvidence::default()
        );
        assert_eq!(
            decode_api_unit_evidence(&json!({"fingerprint": "fp", "deps": "a"})),
            ApiUnitEvidence::default()
        );
    }
}
