use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::sync::Arc;

pub const BINARY_ASSET_RESPONSE_MAGIC: &[u8; 4] = b"BRAB";
pub const BINARY_BUILD_RESULT_MAGIC: &[u8; 4] = b"BRAR";
pub const MAX_FRAME_LENGTH: usize = 256 * 1024 * 1024;
pub const IPC_BUFFER_CAPACITY: usize = 64 * 1024;

#[derive(Debug, Serialize, Deserialize)]
pub struct BuildOutput {
    pub asset: String,
    pub bytes: Arc<[u8]>,
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct Diagnostic {
    pub level: String,
    pub message: String,
    #[serde(default)]
    pub asset: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Eq, PartialEq, Ord, PartialOrd)]
pub struct GlobRead {
    pub package: String,
    pub pattern: String,
}

/// A unit API fingerprint bound to the content digest of the unit
/// that produced it (ADR 0056). Workers report the digest of the
/// exact content they fingerprinted, so the frontend can reject
/// baseline evidence whose bytes are not the committed snapshot's.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiFingerprintRecord {
    /// Bare BLAKE3 hex of the fingerprinted content (no `b3-` prefix,
    /// unlike snapshot digests).
    pub digest: String,
    pub fingerprint: String,
}

/// Merges fingerprint reports into `target`, degrading a disagreement
/// to `None` (evidence dropped) instead of letting the later report
/// win. Two reports for the same asset disagree only when they were
/// learned from different bytes, which a mid-build edit can cause
/// when several workers (or successive results) observe the asset at
/// different times; outputs may have been generated against either
/// observation, so neither report can be trusted as their basis.
/// Once degraded, an entry stays `None` for the rest of the merge
/// scope: a further report cannot resurrect it.
pub fn merge_fingerprint_reports(
    target: &mut BTreeMap<String, Option<ApiFingerprintRecord>>,
    incoming: BTreeMap<String, Option<ApiFingerprintRecord>>,
) {
    for (asset, record) in incoming {
        match target.entry(asset) {
            std::collections::btree_map::Entry::Vacant(entry) => {
                entry.insert(record);
            }
            std::collections::btree_map::Entry::Occupied(mut entry) => {
                if *entry.get() != record {
                    entry.insert(None);
                }
            }
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct BuildResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_us: Option<u64>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shared_part: Option<SharedPart>,
    #[serde(rename = "type")]
    pub message_type: String,
    pub id: u64,
    pub status: String,
    #[serde(default)]
    pub outputs: Vec<BuildOutput>,
    #[serde(default)]
    pub deleted: Vec<String>,
    #[serde(default)]
    pub reads: Vec<String>,
    #[serde(default)]
    pub stock_inputs: Option<Vec<String>>,
    #[serde(default)]
    pub stock_globs: Option<BTreeMap<String, Vec<String>>>,
    #[serde(default)]
    pub resolver_reads: Vec<String>,
    /// Libraries the action touched as source text through the
    /// resolver (ADR 0056), reported under `api-fingerprints-v1`.
    #[serde(default)]
    pub resolver_content_reads: Vec<String>,
    #[serde(default)]
    pub resolver_entrypoints: Vec<String>,
    pub resolver_used: bool,
    #[serde(default)]
    pub glob_reads: Vec<GlobRead>,
    #[serde(default)]
    pub diagnostics: Vec<Diagnostic>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SharedPart {
    pub header: String,
    pub imports: String,
    pub source: String,
    pub original: String,
    pub with_part: Option<String>,
    pub without_part: Option<String>,
}

impl SharedPart {
    /// Move transport fields into their distinct domain lifetimes; no source
    /// strings are cloned or retained in the persisted contribution.
    pub(crate) fn into_parts(
        self,
    ) -> (
        crate::shared_library::SharedContribution,
        crate::shared_library::SourceEditEvidence,
    ) {
        (
            crate::shared_library::SharedContribution {
                header: self.header,
                imports: self.imports,
                source: self.source,
            },
            crate::shared_library::SourceEditEvidence {
                original: self.original,
                with_part: self.with_part,
                without_part: self.without_part,
            },
        )
    }
}

#[derive(Debug)]
pub struct BinaryFrame {
    pub magic: [u8; 4],
    pub metadata: Value,
    payload: Vec<u8>,
    bytes_start: usize,
}

#[derive(Debug)]
pub enum IncomingFrame {
    Json(Value),
    Binary(BinaryFrame),
}

fn reset_retained_buffer(buffer: &mut Vec<u8>) {
    if buffer.capacity() > IPC_BUFFER_CAPACITY {
        *buffer = Vec::new();
    } else {
        buffer.clear();
    }
}

#[cfg(test)]
pub fn write_frame<W: Write, T: Serialize>(writer: &mut W, message: &T) -> io::Result<usize> {
    let mut buffer = Vec::new();
    write_frame_buffered(writer, message, &mut buffer)
}

/// Serializes into a caller-owned buffer kept across calls, so repeated
/// frames do not allocate a fresh payload vector each time and the 4-byte
/// length header is written together with the payload in one write.
pub fn write_frame_buffered<W: Write, T: Serialize>(
    writer: &mut W,
    message: &T,
    buffer: &mut Vec<u8>,
) -> io::Result<usize> {
    let result = write_frame_into_buffer(writer, message, buffer);
    reset_retained_buffer(buffer);
    result
}

fn write_frame_into_buffer<W: Write, T: Serialize>(
    writer: &mut W,
    message: &T,
    buffer: &mut Vec<u8>,
) -> io::Result<usize> {
    buffer.clear();
    buffer.resize(4, 0);
    serde_json::to_writer(&mut *buffer, message).map_err(io::Error::other)?;
    let payload_len = buffer.len() - 4;
    if payload_len > MAX_FRAME_LENGTH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "IPC frame exceeds the 256 MiB safety limit",
        ));
    }
    let length = u32::try_from(payload_len)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "IPC frame is too large"))?;
    buffer[..4].copy_from_slice(&length.to_be_bytes());
    writer.write_all(buffer)?;
    writer.flush()?;
    Ok(buffer.len())
}

#[cfg(test)]
pub fn write_binary_frame<W: Write, T: Serialize>(
    writer: &mut W,
    metadata: &T,
    bytes: &[u8],
) -> io::Result<usize> {
    let mut buffer = Vec::new();
    write_binary_frame_buffered(writer, metadata, bytes, &mut buffer)
}

pub fn write_binary_frame_buffered<W: Write, T: Serialize>(
    writer: &mut W,
    metadata: &T,
    bytes: &[u8],
    buffer: &mut Vec<u8>,
) -> io::Result<usize> {
    write_binary_frame_with_magic_buffered(
        writer,
        BINARY_ASSET_RESPONSE_MAGIC,
        metadata,
        bytes,
        buffer,
    )
}

#[cfg(test)]
pub fn write_binary_frame_with_magic<W: Write, T: Serialize>(
    writer: &mut W,
    magic: &[u8; 4],
    metadata: &T,
    bytes: &[u8],
) -> io::Result<usize> {
    let mut buffer = Vec::new();
    write_binary_frame_with_magic_buffered(writer, magic, metadata, bytes, &mut buffer)
}

pub fn write_binary_frame_with_magic_buffered<W: Write, T: Serialize>(
    writer: &mut W,
    magic: &[u8; 4],
    metadata: &T,
    bytes: &[u8],
    buffer: &mut Vec<u8>,
) -> io::Result<usize> {
    let result = write_binary_frame_into_buffer(writer, magic, metadata, bytes, buffer);
    reset_retained_buffer(buffer);
    result
}

fn write_binary_frame_into_buffer<W: Write, T: Serialize>(
    writer: &mut W,
    magic: &[u8; 4],
    metadata: &T,
    bytes: &[u8],
    buffer: &mut Vec<u8>,
) -> io::Result<usize> {
    const HEADER_LEN: usize = 12;
    buffer.clear();
    buffer.resize(HEADER_LEN, 0);
    serde_json::to_writer(&mut *buffer, metadata).map_err(io::Error::other)?;
    let metadata_len = buffer.len() - HEADER_LEN;
    let payload_length = magic
        .len()
        .checked_add(4)
        .and_then(|length| length.checked_add(metadata_len))
        .and_then(|length| length.checked_add(bytes.len()))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "IPC frame is too large"))?;
    if payload_length > MAX_FRAME_LENGTH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "IPC frame exceeds the 256 MiB safety limit",
        ));
    }
    let metadata_length = u32::try_from(metadata_len)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "IPC metadata is too large"))?;
    let length = u32::try_from(payload_length)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "IPC frame is too large"))?;
    buffer[..4].copy_from_slice(&length.to_be_bytes());
    buffer[4..8].copy_from_slice(magic);
    buffer[8..12].copy_from_slice(&metadata_length.to_be_bytes());
    if buffer.len().saturating_add(bytes.len()) <= IPC_BUFFER_CAPACITY {
        buffer.extend_from_slice(bytes);
        writer.write_all(buffer)?;
    } else {
        writer.write_all(buffer)?;
        writer.write_all(bytes)?;
    }
    writer.flush()?;
    Ok(payload_length + 4)
}

#[cfg(test)]
pub fn read_message_with_size<R: Read>(
    reader: &mut R,
) -> io::Result<Option<(IncomingFrame, usize)>> {
    let mut buffer = Vec::new();
    read_message_with_size_buffered(reader, &mut buffer)
}

/// Reads one frame into a reusable receive buffer. JSON frames decode in place
/// and keep buffer capacity up to `IPC_BUFFER_CAPACITY`; binary frames move
/// ownership of the payload vector without copying.
pub fn read_message_with_size_buffered<R: Read>(
    reader: &mut R,
    buffer: &mut Vec<u8>,
) -> io::Result<Option<(IncomingFrame, usize)>> {
    let mut header = [0_u8; 4];
    match reader.read_exact(&mut header) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }

    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_FRAME_LENGTH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "IPC frame exceeds the 256 MiB safety limit",
        ));
    }

    buffer.resize(length, 0);
    let result = reader
        .read_exact(buffer)
        .and_then(|()| decode_payload_buffered(buffer));
    reset_retained_buffer(buffer);
    Ok(Some((result?, length + 4)))
}

fn decode_payload_buffered(payload: &mut Vec<u8>) -> io::Result<IncomingFrame> {
    if payload.starts_with(BINARY_ASSET_RESPONSE_MAGIC)
        || payload.starts_with(BINARY_BUILD_RESULT_MAGIC)
    {
        if payload.len() < 8 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "binary IPC envelope is truncated",
            ));
        }
        let mut magic = [0_u8; 4];
        magic.copy_from_slice(&payload[..4]);
        let metadata_length = u32::from_be_bytes(payload[4..8].try_into().unwrap()) as usize;
        let metadata_start = 8_usize;
        let bytes_start = metadata_start.checked_add(metadata_length).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "IPC metadata is too large")
        })?;
        if bytes_start > payload.len() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "binary IPC metadata is truncated",
            ));
        }
        let metadata = serde_json::from_slice(&payload[metadata_start..bytes_start])
            .map_err(io::Error::other)?;
        return Ok(IncomingFrame::Binary(BinaryFrame {
            magic,
            metadata,
            payload: std::mem::take(payload),
            bytes_start,
        }));
    }

    serde_json::from_slice(payload)
        .map(IncomingFrame::Json)
        .map_err(io::Error::other)
}

#[derive(Debug, Deserialize)]
struct BinaryBuildOutput {
    asset: String,
    length: u64,
}

#[derive(Debug, Deserialize)]
struct BinaryBuildResultMetadata {
    #[serde(default)]
    execution_us: Option<u64>,
    #[serde(default)]
    shared_part: Option<SharedPart>,
    v: u32,
    #[serde(rename = "type")]
    message_type: String,
    id: u64,
    status: String,
    encoding: Option<String>,
    outputs: Vec<BinaryBuildOutput>,
    deleted: Vec<String>,
    reads: Vec<String>,
    #[serde(default)]
    stock_inputs: Option<Vec<String>>,
    #[serde(default)]
    stock_globs: Option<BTreeMap<String, Vec<String>>>,
    resolver_reads: Vec<String>,
    #[serde(default)]
    resolver_content_reads: Vec<String>,
    resolver_entrypoints: Vec<String>,
    resolver_used: bool,
    glob_reads: Vec<GlobRead>,
    diagnostics: Vec<Diagnostic>,
    #[serde(default)]
    error: Option<String>,
}

impl BinaryBuildResultMetadata {
    fn decode(self, bytes: &[u8], cursor: &mut usize) -> io::Result<BuildResult> {
        if self.v != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported build result protocol version",
            ));
        }
        if self.message_type != "build_result" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "binary frame is not a build result",
            ));
        }
        if self.encoding.as_deref() != Some("raw") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "build result does not use raw output encoding",
            ));
        }

        let mut outputs = Vec::with_capacity(self.outputs.len());
        for output in self.outputs {
            let length = usize::try_from(output.length).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidData, "build output is too large")
            })?;
            let end = cursor.checked_add(length).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "build output overflows")
            })?;
            if end > bytes.len() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "build output bytes are truncated",
                ));
            }
            outputs.push(BuildOutput {
                asset: output.asset,
                // Keep one copy per output; do not retain the entire received frame.
                bytes: Arc::from(&bytes[*cursor..end]),
            });
            *cursor = end;
        }

        Ok(BuildResult {
            execution_us: self.execution_us,
            shared_part: self.shared_part,
            message_type: self.message_type,
            id: self.id,
            status: self.status,
            outputs,
            deleted: self.deleted,
            reads: self.reads,
            stock_inputs: self.stock_inputs,
            stock_globs: self.stock_globs,
            resolver_reads: self.resolver_reads,
            resolver_content_reads: self.resolver_content_reads,
            resolver_entrypoints: self.resolver_entrypoints,
            resolver_used: self.resolver_used,
            glob_reads: self.glob_reads,
            diagnostics: self.diagnostics,
            error: self.error,
        })
    }
}

pub fn decode_build_result_frame(frame: BinaryFrame) -> io::Result<BuildResult> {
    if frame.magic != *BINARY_BUILD_RESULT_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unexpected binary frame for build result",
        ));
    }
    let BinaryFrame {
        metadata,
        payload,
        bytes_start,
        ..
    } = frame;
    let metadata: BinaryBuildResultMetadata =
        serde_json::from_value(metadata).map_err(io::Error::other)?;
    let bytes = &payload[bytes_start..];
    let mut cursor = 0;
    let result = metadata.decode(bytes, &mut cursor)?;
    if cursor != bytes.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "build result contains trailing output bytes",
        ));
    }
    Ok(result)
}

#[derive(Debug, Deserialize)]
struct BinaryBuildBatchResultMetadata {
    #[serde(rename = "type")]
    message_type: String,
    id: u64,
    #[serde(default)]
    encoding: Option<String>,
    results: Vec<BinaryBuildResultMetadata>,
    /// Direct resolver dependency edges the worker's shared loader holds.
    /// Batch-level because every action's result expands through the same
    /// graph, like stock's `previousLibraryCycleGraphLoader`.
    dep_graph: std::collections::BTreeMap<String, Vec<String>>,
    /// Unit API fingerprints the worker's dep walk learned (ADR 0056),
    /// delta-encoded against what it already sent; a null value marks
    /// a unit whose fingerprint is unavailable. Batch-level like the
    /// dep graph: the walk evidence is shared by every action.
    #[serde(default)]
    api_fingerprints: std::collections::BTreeMap<String, Option<ApiFingerprintRecord>>,
}

pub struct DecodedBuildBatchResult {
    pub id: u64,
    pub more: bool,
    pub results: Vec<BuildResult>,
    pub dep_graph: std::collections::BTreeMap<String, Vec<String>>,
    pub api_fingerprints: std::collections::BTreeMap<String, Option<ApiFingerprintRecord>>,
}

pub fn decode_build_batch_result_frame(frame: BinaryFrame) -> io::Result<DecodedBuildBatchResult> {
    if frame.magic != *BINARY_BUILD_RESULT_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unexpected binary frame for build batch result",
        ));
    }
    let BinaryFrame {
        metadata,
        payload,
        bytes_start,
        ..
    } = frame;
    let metadata: BinaryBuildBatchResultMetadata =
        serde_json::from_value(metadata).map_err(io::Error::other)?;
    let more = match metadata.message_type.as_str() {
        "build_batch_result" => false,
        "build_batch_chunk" => true,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "binary frame is not a build batch result",
            ));
        }
    };
    if metadata.encoding.as_deref() != Some("raw") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "build batch result does not use raw output encoding",
        ));
    }

    let bytes = &payload[bytes_start..];
    let mut cursor = 0;
    let results = metadata
        .results
        .into_iter()
        .map(|result| result.decode(bytes, &mut cursor))
        .collect::<io::Result<Vec<_>>>()?;
    if cursor != bytes.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "build batch result contains trailing output bytes",
        ));
    }
    Ok(DecodedBuildBatchResult {
        id: metadata.id,
        more,
        results,
        dep_graph: metadata.dep_graph,
        api_fingerprints: metadata.api_fingerprints,
    })
}

/// Validate transport fragments without copying results on the ordinary
/// single-frame path. Nothing is exposed to the caller before the final frame.
pub struct BuildBatchResultCollector {
    id: u64,
    expected: usize,
    partial: Option<DecodedBuildBatchResult>,
}

impl BuildBatchResultCollector {
    pub fn new(id: u64, expected: usize) -> Self {
        Self {
            id,
            expected,
            partial: None,
        }
    }

    pub fn accept(
        &mut self,
        mut next: DecodedBuildBatchResult,
    ) -> io::Result<Option<DecodedBuildBatchResult>> {
        if next.id != self.id {
            return Err(io::Error::other("worker batch response id mismatch"));
        }
        let offset = self.partial.as_ref().map_or(0, |p| p.results.len());
        if next.results.len() > self.expected.saturating_sub(offset)
            || (!next.more && offset + next.results.len() != self.expected)
        {
            return Err(io::Error::other("worker batch result count mismatch"));
        }
        if next
            .results
            .iter()
            .enumerate()
            .any(|(index, r)| r.id != (offset + index) as u64)
        {
            return Err(io::Error::other("worker batch result id mismatch"));
        }
        if next.more
            && next.results.is_empty()
            && next.dep_graph.is_empty()
            && next.api_fingerprints.is_empty()
        {
            return Err(io::Error::other("worker batch chunk made no progress"));
        }
        if let Some(mut partial) = self.partial.take() {
            for (asset, deps) in next.dep_graph {
                if partial.dep_graph.insert(asset, deps).is_some() {
                    return Err(io::Error::other(
                        "duplicate dependency entry in batch chunks",
                    ));
                }
            }
            for (asset, fingerprint) in next.api_fingerprints {
                if partial
                    .api_fingerprints
                    .insert(asset, fingerprint)
                    .is_some()
                {
                    return Err(io::Error::other(
                        "duplicate fingerprint entry in batch chunks",
                    ));
                }
            }
            partial.results.append(&mut next.results);
            partial.more = next.more;
            next = partial;
        }
        if next.more {
            self.partial = Some(next);
            Ok(None)
        } else {
            Ok(Some(next))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ApiFingerprintRecord, BINARY_ASSET_RESPONSE_MAGIC, BINARY_BUILD_RESULT_MAGIC,
        IncomingFrame, MAX_FRAME_LENGTH, decode_build_batch_result_frame,
        decode_build_result_frame, merge_fingerprint_reports, read_message_with_size,
        write_binary_frame, write_binary_frame_with_magic, write_frame,
    };
    use serde_json::{Value, json};
    use std::collections::BTreeMap;
    use std::io::Cursor;

    #[test]
    fn merge_fingerprint_reports_degrades_disagreements() {
        fn record(digest: &str, fingerprint: &str) -> ApiFingerprintRecord {
            ApiFingerprintRecord {
                digest: digest.to_owned(),
                fingerprint: fingerprint.to_owned(),
            }
        }
        let mut target = BTreeMap::new();
        merge_fingerprint_reports(
            &mut target,
            BTreeMap::from([("app|lib/a.dart".to_owned(), Some(record("d-1", "f-1")))]),
        );
        // An agreeing report keeps the record.
        merge_fingerprint_reports(
            &mut target,
            BTreeMap::from([("app|lib/a.dart".to_owned(), Some(record("d-1", "f-1")))]),
        );
        assert_eq!(
            target.get("app|lib/a.dart"),
            Some(&Some(record("d-1", "f-1")))
        );
        // A disagreeing report drops the evidence, and no later
        // report in the same merge scope resurrects it.
        merge_fingerprint_reports(
            &mut target,
            BTreeMap::from([("app|lib/a.dart".to_owned(), Some(record("d-2", "f-2")))]),
        );
        merge_fingerprint_reports(
            &mut target,
            BTreeMap::from([("app|lib/a.dart".to_owned(), Some(record("d-1", "f-1")))]),
        );
        assert_eq!(target.get("app|lib/a.dart"), Some(&None));
    }

    #[test]
    fn frame_round_trip_uses_length_prefix() {
        let message = json!({"v": 1, "type": "test", "unicode": "日本語"});
        let mut bytes = Vec::new();
        write_frame(&mut bytes, &message).expect("write frame");

        let payload_length = u32::from_be_bytes(bytes[..4].try_into().unwrap());
        assert_eq!(payload_length as usize, bytes.len() - 4);
        let (frame, frame_size) = read_message_with_size(&mut Cursor::new(bytes))
            .unwrap()
            .expect("frame");
        let IncomingFrame::Json(decoded) = frame else {
            panic!("expected JSON frame");
        };
        assert_eq!(decoded, message);
        assert_eq!(frame_size, payload_length as usize + 4);
    }

    #[test]
    fn binary_frame_contains_metadata_and_raw_bytes_in_one_payload() {
        let metadata = json!({
            "v": 1,
            "type": "asset_response",
            "id": 1000,
            "ok": true,
            "encoding": "raw",
            "length": 7,
        });
        let raw_bytes = b"payload";
        let mut bytes = Vec::new();
        write_binary_frame(&mut bytes, &metadata, raw_bytes).expect("write binary frame");

        let payload_length = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
        assert_eq!(payload_length, bytes.len() - 4);
        assert_eq!(&bytes[4..8], BINARY_ASSET_RESPONSE_MAGIC);
        let metadata_length = u32::from_be_bytes(bytes[8..12].try_into().unwrap()) as usize;
        let metadata_start = 12;
        let raw_start = metadata_start + metadata_length;
        assert_eq!(
            serde_json::from_slice::<Value>(&bytes[metadata_start..raw_start]).unwrap(),
            metadata
        );
        assert_eq!(&bytes[raw_start..], raw_bytes);
    }

    #[test]
    fn build_result_binary_frame_preserves_raw_outputs() {
        let metadata = json!({
            "v": 1,
            "type": "build_result",
            "id": 2,
            "status": "success",
            "execution_us": 23000,
            "encoding": "raw",
            "outputs": [{"asset": "app|lib/model.g.dart", "length": 7}],
            "reads": [],
            "resolver_reads": [],
                    "resolver_entrypoints": [],
                    "deleted": [],
            "resolver_used": true,
            "glob_reads": [],
            "diagnostics": []
        });
        let raw_bytes = b"payload";
        let mut bytes = Vec::new();
        write_binary_frame_with_magic(&mut bytes, BINARY_BUILD_RESULT_MAGIC, &metadata, raw_bytes)
            .expect("write build result binary frame");

        let (frame, frame_size) = read_message_with_size(&mut Cursor::new(bytes))
            .unwrap()
            .expect("frame");
        let IncomingFrame::Binary(frame) = frame else {
            panic!("expected binary frame");
        };
        assert_eq!(frame.magic, *BINARY_BUILD_RESULT_MAGIC);
        assert_eq!(&frame.payload[frame.bytes_start..], raw_bytes);
        assert_eq!(
            frame_size,
            4 + 4 + 4 + frame.metadata.to_string().len() + raw_bytes.len()
        );

        let result = decode_build_result_frame(frame).expect("decode build result");
        assert_eq!(result.id, 2);
        assert_eq!(result.execution_us, Some(23000));
        assert_eq!(result.outputs[0].asset, "app|lib/model.g.dart");
        assert_eq!(result.outputs[0].bytes.as_ref(), raw_bytes);
        assert!(result.resolver_used);
    }

    #[test]
    fn build_batch_binary_frame_restores_all_output_ranges() {
        let metadata = json!({
            "v": 1,
            "type": "build_batch_result",
            "id": 7,
            "encoding": "raw",
            "dep_graph": {},
            "results": [
                {
                    "v": 1,
                    "type": "build_result",
                    "id": 0,
                    "status": "success",
                    "encoding": "raw",
                    "outputs": [{"asset": "app|a.g.dart", "length": 3}],
                    "reads": [],
                    "resolver_reads": [],
                    "resolver_entrypoints": [],
                    "deleted": [],
                    "resolver_used": false,
                    "glob_reads": [],
                    "diagnostics": []
                },
                {
                    "v": 1,
                    "type": "build_result",
                    "id": 1,
                    "status": "success",
                    "encoding": "raw",
                    "outputs": [{"asset": "app|b.g.dart", "length": 4}],
                    "reads": [],
                    "resolver_reads": [],
                    "resolver_entrypoints": [],
                    "deleted": [],
                    "resolver_used": false,
                    "glob_reads": [],
                    "diagnostics": []
                }
            ]
        });
        let raw_bytes = b"onefour";
        let mut bytes = Vec::new();
        write_binary_frame_with_magic(&mut bytes, BINARY_BUILD_RESULT_MAGIC, &metadata, raw_bytes)
            .expect("write build batch result binary frame");

        let (frame, _) = read_message_with_size(&mut Cursor::new(bytes))
            .unwrap()
            .expect("frame");
        let IncomingFrame::Binary(frame) = frame else {
            panic!("expected binary frame");
        };
        let decoded = decode_build_batch_result_frame(frame).expect("decode build batch result");
        assert_eq!(decoded.id, 7);
        assert_eq!(decoded.results.len(), 2);
        assert!(!decoded.results[0].resolver_used);
        assert!(!decoded.results[1].resolver_used);
        assert_eq!(decoded.results[0].outputs[0].bytes.as_ref(), b"one");
        assert_eq!(decoded.results[1].outputs[0].bytes.as_ref(), b"four");
    }

    #[test]
    fn missing_result_dependencies_and_wrong_versions_fail_explicitly() {
        let valid = json!({"v": 1, "type": "build_result", "id": 1, "status": "success", "encoding": "raw", "outputs": [], "deleted": [], "reads": [], "resolver_reads": [], "resolver_entrypoints": [], "resolver_used": false, "glob_reads": [], "diagnostics": []});
        let decode = |metadata: Value| {
            let mut bytes = Vec::new();
            write_binary_frame_with_magic(&mut bytes, BINARY_BUILD_RESULT_MAGIC, &metadata, b"")
                .unwrap();
            let (IncomingFrame::Binary(frame), _) = read_message_with_size(&mut Cursor::new(bytes))
                .unwrap()
                .unwrap()
            else {
                panic!("binary frame")
            };
            decode_build_result_frame(frame)
        };
        assert!(decode(valid.clone()).is_ok());
        for field in [
            "v",
            "outputs",
            "deleted",
            "reads",
            "resolver_reads",
            "resolver_entrypoints",
            "resolver_used",
            "glob_reads",
            "diagnostics",
        ] {
            let mut missing = valid.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(decode(missing).is_err(), "missing {field}");
        }
        let mut mismatch = valid;
        mismatch["v"] = json!(2);
        assert!(decode(mismatch).is_err());
    }

    #[test]
    fn frame_length_limit_is_checked_before_allocation() {
        let length = (MAX_FRAME_LENGTH as u32 + 1).to_be_bytes();
        let error = read_message_with_size(&mut Cursor::new(length))
            .expect_err("oversized frame must be rejected");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }

    fn batch_fragment(
        id: u64,
        ids: &[u64],
        more: bool,
        graph: Value,
    ) -> super::DecodedBuildBatchResult {
        batch_fragment_with_fingerprints(id, ids, more, graph, json!({}))
    }

    fn batch_fragment_with_fingerprints(
        id: u64,
        ids: &[u64],
        more: bool,
        graph: Value,
        fingerprints: Value,
    ) -> super::DecodedBuildBatchResult {
        let metadata = json!({
            "v": 1, "type": if more { "build_batch_chunk" } else { "build_batch_result" },
            "id": id, "encoding": "raw", "dep_graph": graph,
            "api_fingerprints": fingerprints,
            "results": ids.iter().map(|id| json!({
                "v": 1, "type": "build_result", "id": id, "status": "success",
                "encoding": "raw", "execution_us": 5000, "outputs": [],
                "deleted": [], "reads": [], "resolver_reads": [],
                "resolver_content_reads": ["app|lib/dep.dart"],
                "resolver_entrypoints": [], "resolver_used": false,
                "glob_reads": [], "diagnostics": []
            })).collect::<Vec<_>>()
        });
        let mut bytes = Vec::new();
        write_binary_frame_with_magic(&mut bytes, BINARY_BUILD_RESULT_MAGIC, &metadata, &[])
            .unwrap();
        let IncomingFrame::Binary(frame) = read_message_with_size(&mut Cursor::new(bytes))
            .unwrap()
            .unwrap()
            .0
        else {
            panic!("expected binary result");
        };
        decode_build_batch_result_frame(frame).unwrap()
    }

    #[test]
    fn batch_result_collector_keeps_the_single_frame_allocation() {
        let decoded = batch_fragment(42, &[0, 1], false, json!({}));
        let original = decoded.results.as_ptr();
        let mut collector = super::BuildBatchResultCollector::new(42, 2);
        let result = collector.accept(decoded).unwrap().unwrap();
        assert_eq!(result.results.as_ptr(), original);
        assert!(!result.more);
    }

    #[test]
    fn batch_chunks_are_not_exposed_until_results_and_graph_are_complete() {
        let mut collector = super::BuildBatchResultCollector::new(42, 3);
        assert!(
            collector
                .accept(batch_fragment(42, &[0, 1], true, json!({})))
                .unwrap()
                .is_none()
        );
        assert!(
            collector
                .accept(batch_fragment(42, &[2], true, json!({"app|a": ["app|b"]})))
                .unwrap()
                .is_none()
        );
        let result = collector
            .accept(batch_fragment(42, &[], false, json!({"app|c": []})))
            .unwrap()
            .unwrap();
        assert_eq!(
            result.results.iter().map(|r| r.id).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
        assert!(result.results.iter().all(|r| r.execution_us == Some(5000)));
        assert_eq!(result.dep_graph.len(), 2);
        assert!(!result.more);
    }

    #[test]
    fn batch_chunks_reject_wrong_ids_counts_and_empty_progress() {
        for (id, ids, more) in [
            (43, vec![1], false),
            (42, vec![0], false),
            (42, vec![2], false),
            (42, vec![1, 2], false),
            (42, vec![], false),
            (42, vec![], true),
        ] {
            let mut collector = super::BuildBatchResultCollector::new(42, 2);
            assert!(
                collector
                    .accept(batch_fragment(42, &[0], true, json!({})))
                    .unwrap()
                    .is_none()
            );
            assert!(
                collector
                    .accept(batch_fragment(id, &ids, more, json!({})))
                    .is_err()
            );
        }
    }

    #[test]
    fn batch_chunks_reject_duplicate_dependency_entries() {
        let mut collector = super::BuildBatchResultCollector::new(42, 1);
        assert!(
            collector
                .accept(batch_fragment(42, &[0], true, json!({"app|a": []})))
                .unwrap()
                .is_none()
        );
        assert!(
            collector
                .accept(batch_fragment(42, &[], false, json!({"app|a": ["app|b"]})))
                .is_err()
        );
    }

    #[test]
    fn batch_result_decodes_api_fingerprints_and_content_reads() {
        let decoded = batch_fragment_with_fingerprints(
            42,
            &[0],
            false,
            json!({}),
            json!({
                "app|lib/a.dart": {"digest": "d-a", "fingerprint": "fp-a"},
                "app|lib/b.dart": null,
            }),
        );
        assert_eq!(
            decoded.api_fingerprints,
            std::collections::BTreeMap::from([
                (
                    "app|lib/a.dart".to_owned(),
                    Some(super::ApiFingerprintRecord {
                        digest: "d-a".to_owned(),
                        fingerprint: "fp-a".to_owned(),
                    }),
                ),
                ("app|lib/b.dart".to_owned(), None),
            ])
        );
        assert_eq!(
            decoded.results[0].resolver_content_reads,
            vec!["app|lib/dep.dart".to_owned()]
        );
    }

    #[test]
    fn batch_chunks_merge_fingerprints_and_reject_duplicates() {
        let mut collector = super::BuildBatchResultCollector::new(42, 1);
        assert!(
            collector
                .accept(batch_fragment_with_fingerprints(
                    42,
                    &[0],
                    true,
                    json!({}),
                    json!({"app|lib/a.dart": {"digest": "d-a", "fingerprint": "fp-a"}}),
                ))
                .unwrap()
                .is_none()
        );
        let result = collector
            .accept(batch_fragment_with_fingerprints(
                42,
                &[],
                false,
                json!({}),
                json!({"app|lib/b.dart": null}),
            ))
            .unwrap()
            .unwrap();
        assert_eq!(result.api_fingerprints.len(), 2);

        let mut collector = super::BuildBatchResultCollector::new(42, 1);
        assert!(
            collector
                .accept(batch_fragment_with_fingerprints(
                    42,
                    &[0],
                    true,
                    json!({}),
                    json!({"app|lib/a.dart": {"digest": "d-a", "fingerprint": "fp-a"}}),
                ))
                .unwrap()
                .is_none()
        );
        assert!(
            collector
                .accept(batch_fragment_with_fingerprints(
                    42,
                    &[],
                    false,
                    json!({}),
                    json!({"app|lib/a.dart": null}),
                ))
                .is_err()
        );
    }

    struct RecordingWriter {
        writes: Vec<Vec<u8>>,
    }

    impl RecordingWriter {
        fn new() -> Self {
            Self { writes: Vec::new() }
        }

        fn joined(&self) -> Vec<u8> {
            self.writes.concat()
        }
    }

    impl std::io::Write for RecordingWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.writes.push(buf.to_vec());
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn buffered_json_write_coalesces_header_and_bounds_retained_capacity() {
        let mut writer = RecordingWriter::new();
        let mut buffer = Vec::new();

        // 10 KiB frame (> default 8 KiB BufWriter) must still emit in a single write.
        let medium = json!({"v": 1, "type": "medium", "data": "x".repeat(10 * 1024)});
        super::write_frame_buffered(&mut writer, &medium, &mut buffer).expect("write medium");
        assert_eq!(writer.writes.len(), 1);
        assert!(buffer.is_empty());
        assert!(buffer.capacity() >= 10 * 1024);
        assert!(buffer.capacity() <= super::IPC_BUFFER_CAPACITY);

        // Oversized frame (> 64 KiB) releases the retained buffer after flushing.
        let large = json!({"v": 1, "type": "large", "data": "y".repeat(70 * 1024)});
        super::write_frame_buffered(&mut writer, &large, &mut buffer).expect("write large");
        assert_eq!(writer.writes.len(), 2);
        assert_eq!(buffer.capacity(), 0);

        let mut cursor = Cursor::new(writer.joined());
        let mut recv_buffer = Vec::new();
        let (IncomingFrame::Json(first), _) =
            super::read_message_with_size_buffered(&mut cursor, &mut recv_buffer)
                .expect("read medium")
                .expect("frame")
        else {
            panic!("expected JSON frame");
        };
        assert_eq!(first, medium);
        assert!(recv_buffer.capacity() >= 10 * 1024);
        assert!(recv_buffer.capacity() <= super::IPC_BUFFER_CAPACITY);

        let (IncomingFrame::Json(second), _) =
            super::read_message_with_size_buffered(&mut cursor, &mut recv_buffer)
                .expect("read large")
                .expect("frame")
        else {
            panic!("expected JSON frame");
        };
        assert_eq!(second, large);
        assert_eq!(recv_buffer.capacity(), 0);
    }

    #[test]
    fn buffered_binary_write_coalesces_small_frames_and_streams_large_payloads() {
        let mut writer = RecordingWriter::new();
        let mut buffer = Vec::new();

        let small_bytes = vec![7_u8; 2 * 1024];
        let small_meta = json!({
            "v": 1,
            "type": "asset_response",
            "id": 1,
            "ok": true,
            "encoding": "raw",
            "length": small_bytes.len(),
        });
        super::write_binary_frame_buffered(&mut writer, &small_meta, &small_bytes, &mut buffer)
            .expect("write small binary");
        assert_eq!(writer.writes.len(), 1);
        assert!(buffer.capacity() <= super::IPC_BUFFER_CAPACITY);

        let large_bytes = vec![9_u8; 70 * 1024];
        let large_meta = json!({
            "v": 1,
            "type": "asset_response",
            "id": 2,
            "ok": true,
            "encoding": "raw",
            "length": large_bytes.len(),
        });
        super::write_binary_frame_buffered(&mut writer, &large_meta, &large_bytes, &mut buffer)
            .expect("write large binary");
        // Header+metadata in one write, raw payload in the second write.
        assert_eq!(writer.writes.len(), 3);
        assert_eq!(writer.writes[2].len(), large_bytes.len());

        let mut cursor = Cursor::new(writer.joined());
        let mut recv_buffer = Vec::new();
        for (expected_meta, expected_bytes) in
            [(small_meta, small_bytes), (large_meta, large_bytes)]
        {
            let (IncomingFrame::Binary(frame), _) =
                super::read_message_with_size_buffered(&mut cursor, &mut recv_buffer)
                    .expect("read binary")
                    .expect("frame")
            else {
                panic!("expected binary frame");
            };
            assert_eq!(frame.metadata, expected_meta);
            assert_eq!(
                &frame.payload[frame.bytes_start..],
                expected_bytes.as_slice()
            );
            // Ownership moved into BinaryFrame.
            assert_eq!(recv_buffer.capacity(), 0);
        }
    }
}
