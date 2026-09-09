use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{self, Read, Write};

pub const BINARY_ASSET_RESPONSE_MAGIC: &[u8; 4] = b"FBRB";
pub const BINARY_BUILD_RESULT_MAGIC: &[u8; 4] = b"FBRR";
pub const MAX_FRAME_LENGTH: usize = 256 * 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
pub struct BuildOutput {
    pub asset: String,
    pub bytes: Vec<u8>,
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

#[derive(Debug, Serialize, Deserialize)]
pub struct BuildResult {
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
    pub resolver_reads: Vec<String>,
    #[serde(default)]
    pub glob_reads: Vec<GlobRead>,
    #[serde(default)]
    pub diagnostics: Vec<Diagnostic>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
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

pub fn write_frame<W: Write, T: Serialize>(writer: &mut W, message: &T) -> io::Result<usize> {
    let payload = serde_json::to_vec(message).map_err(io::Error::other)?;
    write_payload(writer, &payload)
}

pub fn write_binary_frame<W: Write, T: Serialize>(
    writer: &mut W,
    metadata: &T,
    bytes: &[u8],
) -> io::Result<usize> {
    write_binary_frame_with_magic(writer, BINARY_ASSET_RESPONSE_MAGIC, metadata, bytes)
}

pub fn write_binary_frame_with_magic<W: Write, T: Serialize>(
    writer: &mut W,
    magic: &[u8; 4],
    metadata: &T,
    bytes: &[u8],
) -> io::Result<usize> {
    let metadata = serde_json::to_vec(metadata).map_err(io::Error::other)?;
    let payload_length = magic
        .len()
        .checked_add(4)
        .and_then(|length| length.checked_add(metadata.len()))
        .and_then(|length| length.checked_add(bytes.len()))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "IPC frame is too large"))?;
    if payload_length > MAX_FRAME_LENGTH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "IPC frame exceeds the 256 MiB safety limit",
        ));
    }
    let metadata_length = u32::try_from(metadata.len()).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidData, "IPC metadata is too large")
    })?;
    let length = u32::try_from(payload_length)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "IPC frame is too large"))?;
    writer.write_all(&length.to_be_bytes())?;
    writer.write_all(magic)?;
    writer.write_all(&metadata_length.to_be_bytes())?;
    writer.write_all(&metadata)?;
    writer.write_all(bytes)?;
    writer.flush()?;
    Ok(payload_length + 4)
}

fn write_payload<W: Write>(writer: &mut W, payload: &[u8]) -> io::Result<usize> {
    if payload.len() > MAX_FRAME_LENGTH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "IPC frame exceeds the 256 MiB safety limit",
        ));
    }
    let length = u32::try_from(payload.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "IPC frame is too large"))?;
    writer.write_all(&length.to_be_bytes())?;
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(payload.len() + 4)
}

pub fn read_message_with_size<R: Read>(
    reader: &mut R,
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

    let mut payload = vec![0_u8; length];
    reader.read_exact(&mut payload)?;
    Ok(Some((decode_payload(payload)?, length + 4)))
}

fn decode_payload(payload: Vec<u8>) -> io::Result<IncomingFrame> {
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
        let bytes_start = metadata_start
            .checked_add(metadata_length)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "IPC metadata is too large"))?;
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
            payload,
            bytes_start,
        }));
    }

    serde_json::from_slice(&payload)
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
    #[serde(rename = "type")]
    message_type: String,
    id: u64,
    status: String,
    #[serde(default)]
    encoding: Option<String>,
    #[serde(default)]
    outputs: Vec<BinaryBuildOutput>,
    #[serde(default)]
    deleted: Vec<String>,
    #[serde(default)]
    reads: Vec<String>,
    #[serde(default)]
    resolver_reads: Vec<String>,
    #[serde(default)]
    glob_reads: Vec<GlobRead>,
    #[serde(default)]
    diagnostics: Vec<Diagnostic>,
    #[serde(default)]
    error: Option<String>,
}

impl BinaryBuildResultMetadata {
    fn decode(self, bytes: &[u8], cursor: &mut usize) -> io::Result<BuildResult> {
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
            let end = cursor
                .checked_add(length)
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "build output overflows"))?;
            if end > bytes.len() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "build output bytes are truncated",
                ));
            }
            outputs.push(BuildOutput {
                asset: output.asset,
                bytes: bytes[*cursor..end].to_vec(),
            });
            *cursor = end;
        }

        Ok(BuildResult {
            message_type: self.message_type,
            id: self.id,
            status: self.status,
            outputs,
            deleted: self.deleted,
            reads: self.reads,
            resolver_reads: self.resolver_reads,
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
}

pub struct DecodedBuildBatchResult {
    pub id: u64,
    pub results: Vec<BuildResult>,
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
    if metadata.message_type != "build_batch_result" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "binary frame is not a build batch result",
        ));
    }
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
        results,
    })
}

#[cfg(test)]
mod tests {
    use super::{
        decode_build_batch_result_frame, decode_build_result_frame, read_message_with_size,
        write_binary_frame, write_binary_frame_with_magic, write_frame, IncomingFrame,
        BINARY_ASSET_RESPONSE_MAGIC, BINARY_BUILD_RESULT_MAGIC, MAX_FRAME_LENGTH,
    };
    use serde_json::{json, Value};
    use std::io::Cursor;

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
            "encoding": "raw",
            "outputs": [{"asset": "app|lib/model.g.dart", "length": 7}],
            "reads": [],
            "resolver_reads": [],
            "glob_reads": [],
            "diagnostics": []
        });
        let raw_bytes = b"payload";
        let mut bytes = Vec::new();
        write_binary_frame_with_magic(
            &mut bytes,
            BINARY_BUILD_RESULT_MAGIC,
            &metadata,
            raw_bytes,
        )
        .expect("write build result binary frame");

        let (frame, frame_size) = read_message_with_size(&mut Cursor::new(bytes))
            .unwrap()
            .expect("frame");
        let IncomingFrame::Binary(frame) = frame else {
            panic!("expected binary frame");
        };
        assert_eq!(frame.magic, *BINARY_BUILD_RESULT_MAGIC);
        assert_eq!(&frame.payload[frame.bytes_start..], raw_bytes);
        assert_eq!(frame_size, 4 + 4 + 4 + frame.metadata.to_string().len() + raw_bytes.len());

        let result = decode_build_result_frame(frame).expect("decode build result");
        assert_eq!(result.id, 2);
        assert_eq!(result.outputs[0].asset, "app|lib/model.g.dart");
        assert_eq!(result.outputs[0].bytes, raw_bytes);
    }

    #[test]
    fn build_batch_binary_frame_restores_all_output_ranges() {
        let metadata = json!({
            "v": 1,
            "type": "build_batch_result",
            "id": 7,
            "encoding": "raw",
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
                    "glob_reads": [],
                    "diagnostics": []
                }
            ]
        });
        let raw_bytes = b"onefour";
        let mut bytes = Vec::new();
        write_binary_frame_with_magic(
            &mut bytes,
            BINARY_BUILD_RESULT_MAGIC,
            &metadata,
            raw_bytes,
        )
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
        assert_eq!(decoded.results[0].outputs[0].bytes, b"one");
        assert_eq!(decoded.results[1].outputs[0].bytes, b"four");
    }

    #[test]
    fn frame_length_limit_is_checked_before_allocation() {
        let length = (MAX_FRAME_LENGTH as u32 + 1).to_be_bytes();
        let error = read_message_with_size(&mut Cursor::new(length))
            .expect_err("oversized frame must be rejected");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }
}
