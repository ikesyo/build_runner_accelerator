use super::{ActionState, GRAPH_SCHEMA_VERSION, GraphState};
use crate::protocol::GlobRead;
use crate::snapshot::{AssetSnapshot, Snapshot};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::Path;

/// Schema 9 added per-action resolver content reads and per-asset API
/// fingerprints to the graph body. Schema 8 bodies lack both fields,
/// so the codec writes and reads them only at this schema or later.
/// Publication recovery validates pre-upgrade journals without the
/// schema gate and relies on this dispatch.
const GRAPH_SCHEMA_API_FINGERPRINTS: u32 = 9;
/// Schema 10 stores each fingerprint as a digest-bound record;
/// schema 9 stored the bare fingerprint string, so the two layouts
/// need distinct version gates for recovery to decode a schema 9
/// journal with its own layout.
const GRAPH_SCHEMA_API_FINGERPRINT_RECORDS: u32 = 10;
pub(super) const GRAPH_MAGIC: &[u8; 4] = b"BRAG";
pub(super) const GRAPH_FORMAT_VERSION: u8 = 3;
const GRAPH_HEADER_LENGTH: usize = GRAPH_MAGIC.len() + 1 + 4;
const GRAPH_MAX_BYTES: usize = 256 * 1024 * 1024;
const GRAPH_MAX_COLLECTION_ITEMS: usize = 4_000_000;

impl GraphState {
    /// Under the workspace writer lock, recover unfinished publication before
    /// reading or invalidating state. Recovery errors never invalidate ownership.
    /// Loads persisted incremental evidence, or starts with an empty graph if
    /// the file is absent or invalid. Invalid bytes are diagnosed and left in
    /// place until a later save; unrelated filesystem errors propagate.
    pub fn load(path: &Path) -> io::Result<Self> {
        crate::build::recovery::recover(path)?;
        match Self::load_checked(path) {
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                eprintln!(
                    "build_runner_accelerator: invalidating graph {}: {error}",
                    path.display()
                );
                Ok(Self {
                    schema_version: GRAPH_SCHEMA_VERSION,
                    ..Self::default()
                })
            }
            result => result,
        }
    }

    /// Validates the graph header, schema, bounds, and complete payload before
    /// constructing state. Only the current private format is decoded; obsolete
    /// formats and malformed payloads return `InvalidData` to `load` for
    /// automatic invalidation, without deleting generated files.
    pub(super) fn load_checked(path: &Path) -> io::Result<Self> {
        let contents = match fs::read(path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(Self {
                    schema_version: GRAPH_SCHEMA_VERSION,
                    ..Self::default()
                });
            }
            Err(error) => return Err(error),
        };
        Self::decode_checked(&contents, true)
    }

    /// Recovery validates the recorded binary layout without changing its
    /// bytes or dropping ownership evidence. Ordinary loading may invalidate
    /// an obsolete cache schema only after file rollback has completed.
    pub(crate) fn decode_checked(contents: &[u8], invalidate_obsolete: bool) -> io::Result<Self> {
        if contents.len() < GRAPH_HEADER_LENGTH {
            return Err(invalid_graph("graph file is truncated"));
        }
        if contents.len() > GRAPH_HEADER_LENGTH + GRAPH_MAX_BYTES {
            return Err(invalid_graph("graph file exceeds the 256 MiB safety limit"));
        }
        if &contents[..GRAPH_MAGIC.len()] != GRAPH_MAGIC {
            return Err(invalid_graph("graph file has an unknown magic"));
        }
        let format_version = contents[GRAPH_MAGIC.len()];
        if format_version != GRAPH_FORMAT_VERSION {
            return Err(invalid_graph(
                "graph file has an unsupported format version",
            ));
        }

        let mut length_bytes = [0_u8; 4];
        length_bytes.copy_from_slice(&contents[GRAPH_MAGIC.len() + 1..GRAPH_HEADER_LENGTH]);
        let payload_length = u32::from_be_bytes(length_bytes) as usize;
        if payload_length != contents.len() - GRAPH_HEADER_LENGTH {
            return Err(invalid_graph(
                "graph payload length does not match file length",
            ));
        }

        let mut decoder = Decoder::new(&contents[GRAPH_HEADER_LENGTH..]);
        let schema_version = decoder.read_u32()?;
        if schema_version != GRAPH_SCHEMA_VERSION && invalidate_obsolete {
            eprintln!(
                "build_runner_accelerator: invalidating graph schema {schema_version}; expected {GRAPH_SCHEMA_VERSION}"
            );
            // Obsolete cache evidence must not be reused during normal loading.
            // Recovery instead validates the saved layout before restoring it.
            return Ok(Self {
                schema_version: GRAPH_SCHEMA_VERSION,
                ..Self::default()
            });
        }
        let state = decoder.read_graph_state(schema_version)?;
        decoder.finish()?;
        Ok(state)
    }

    /// Encodes to a sibling temporary file and renames it over the graph only
    /// after encoding and writing succeed. This protects the graph file from a
    /// partial write, but does not fsync it or make output-file commits atomic.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::other("graph path has no parent"))?;
        fs::create_dir_all(parent)?;
        let temporary = path.with_extension("bin.tmp");
        let mut encoder = Encoder::new();
        encoder.write_graph_state(self)?;
        let payload = encoder.finish();
        let payload_length = u32::try_from(payload.len())
            .map_err(|_| invalid_graph("graph payload exceeds the 4 GiB format limit"))?;
        let mut contents = Vec::with_capacity(GRAPH_HEADER_LENGTH + payload.len());
        contents.extend_from_slice(GRAPH_MAGIC);
        contents.push(GRAPH_FORMAT_VERSION);
        contents.extend_from_slice(&payload_length.to_be_bytes());
        contents.extend_from_slice(&payload);
        fs::write(&temporary, contents)?;
        fs::rename(temporary, path)
    }
}

fn invalid_graph(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

pub(super) struct Encoder {
    bytes: Vec<u8>,
}

impl Encoder {
    pub(super) fn new() -> Self {
        Self { bytes: Vec::new() }
    }

    pub(super) fn finish(self) -> Vec<u8> {
        self.bytes
    }

    /// Appends only if checked length arithmetic stays within the graph limit.
    fn append(&mut self, bytes: &[u8]) -> io::Result<()> {
        let new_length = self
            .bytes
            .len()
            .checked_add(bytes.len())
            .ok_or_else(|| invalid_graph("graph payload length overflow"))?;
        if new_length > GRAPH_MAX_BYTES {
            return Err(invalid_graph(
                "graph payload exceeds the 256 MiB safety limit",
            ));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }

    fn write_u8(&mut self, value: u8) -> io::Result<()> {
        self.append(&[value])
    }

    fn write_u32(&mut self, value: u32) -> io::Result<()> {
        self.append(&value.to_be_bytes())
    }

    fn write_u64(&mut self, value: u64) -> io::Result<()> {
        self.append(&value.to_be_bytes())
    }

    fn write_count(&mut self, count: usize, label: &str) -> io::Result<()> {
        if count > GRAPH_MAX_COLLECTION_ITEMS {
            return Err(invalid_graph(format!(
                "{label} count exceeds the graph safety limit"
            )));
        }
        self.write_u32(u32::try_from(count).map_err(|_| invalid_graph("graph count is too large"))?)
    }

    fn write_string(&mut self, value: &str) -> io::Result<()> {
        let bytes = value.as_bytes();
        let length =
            u32::try_from(bytes.len()).map_err(|_| invalid_graph("graph string is too large"))?;
        self.write_u32(length)?;
        self.append(bytes)
    }

    fn write_strings(&mut self, values: &[String], label: &str) -> io::Result<()> {
        self.write_count(values.len(), label)?;
        for value in values {
            self.write_string(value)?;
        }
        Ok(())
    }

    fn write_string_map(&mut self, values: &BTreeMap<String, String>) -> io::Result<()> {
        self.write_count(values.len(), "string map")?;
        for (key, value) in values {
            self.write_string(key)?;
            self.write_string(value)?;
        }
        Ok(())
    }

    fn write_api_fingerprints(
        &mut self,
        values: &BTreeMap<String, crate::protocol::ApiFingerprintRecord>,
    ) -> io::Result<()> {
        self.write_count(values.len(), "api fingerprints")?;
        for (asset, record) in values {
            self.write_string(asset)?;
            self.write_string(&record.digest)?;
            self.write_string(&record.fingerprint)?;
        }
        Ok(())
    }

    /// The schema 9 layout: the bare fingerprint string per asset,
    /// with no content digest binding.
    fn write_api_fingerprint_strings(
        &mut self,
        values: &BTreeMap<String, crate::protocol::ApiFingerprintRecord>,
    ) -> io::Result<()> {
        self.write_count(values.len(), "api fingerprints")?;
        for (asset, record) in values {
            self.write_string(asset)?;
            self.write_string(&record.fingerprint)?;
        }
        Ok(())
    }

    fn write_snapshot(&mut self, snapshot: &Snapshot) -> io::Result<()> {
        self.write_count(snapshot.len(), "asset snapshot")?;
        for (asset, entry) in snapshot {
            self.write_string(asset)?;
            self.write_u8(u8::from(entry.exists))?;
            self.write_string(&entry.digest)?;
            self.write_u64(entry.size)?;
        }
        Ok(())
    }

    fn write_action(&mut self, action: &ActionState, schema_version: u32) -> io::Result<()> {
        self.write_u8(u8::from(action.shared_part.is_some()))?;
        if let Some(part) = &action.shared_part {
            // Source-edit candidates are transaction-only. Persist reusable
            // contribution sections, without duplicating handwritten sources.
            self.write_string(&part.header)?;
            self.write_string(&part.imports)?;
            self.write_string(&part.source)?;
        }
        self.write_string(&action.builder)?;
        self.write_string(&action.input)?;
        self.write_strings(&action.reads, "action reads")?;
        self.write_strings(&action.resolver_reads, "resolver reads")?;
        if schema_version >= GRAPH_SCHEMA_API_FINGERPRINTS {
            self.write_strings(&action.resolver_content_reads, "resolver content reads")?;
        }
        self.write_strings(&action.resolver_entrypoints, "resolver entrypoints")?;
        self.write_count(action.glob_reads.len(), "glob reads")?;
        for glob in &action.glob_reads {
            self.write_string(&glob.package)?;
            self.write_string(&glob.pattern)?;
        }
        self.write_strings(&action.outputs, "action outputs")?;
        self.write_string_map(&action.output_digests)?;
        self.write_string(&action.status)
    }

    pub(super) fn write_graph_state(&mut self, state: &GraphState) -> io::Result<()> {
        self.write_u32(state.schema_version)?;
        self.write_string(&state.config_digest)?;
        self.write_u8(u8::from(state.was_filtered))?;
        self.write_snapshot(&state.assets)?;
        self.write_count(state.actions.len(), "action graph")?;
        for (key, action) in &state.actions {
            self.write_string(key)?;
            self.write_action(action, state.schema_version)?;
        }
        self.write_string_list_map(&state.resolver_dep_graph)?;
        if state.schema_version >= GRAPH_SCHEMA_API_FINGERPRINT_RECORDS {
            self.write_api_fingerprints(&state.asset_fingerprints)?;
        } else if state.schema_version >= GRAPH_SCHEMA_API_FINGERPRINTS {
            self.write_api_fingerprint_strings(&state.asset_fingerprints)?;
        }
        self.write_count(state.output_locations.len(), "output locations")?;
        for (asset, cache) in &state.output_locations {
            self.write_string(asset)?;
            self.write_u8(u8::from(*cache))?;
        }
        self.write_string_list_map(&state.stock_input_order)?;
        self.write_count(state.stock_glob_members.len(), "stock glob actions")?;
        for (key, globs) in &state.stock_glob_members {
            self.write_string(key)?;
            self.write_string_list_map(globs)?;
        }
        self.write_strings(
            &state
                .watch_generated_sources
                .iter()
                .cloned()
                .collect::<Vec<_>>(),
            "watch generated sources",
        )?;
        self.write_u8(u8::from(state.retained_output_state))?;
        Ok(())
    }

    fn write_string_list_map(&mut self, values: &BTreeMap<String, Vec<String>>) -> io::Result<()> {
        self.write_count(values.len(), "resolver dep graph")?;
        for (key, value) in values {
            self.write_string(key)?;
            self.write_strings(value, "resolver dep graph edges")?;
        }
        Ok(())
    }
}

struct Decoder<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Decoder<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    /// Returns the next range and advances the cursor; truncation and offset
    /// overflow are invalid persisted data rather than panics.
    fn take(&mut self, length: usize) -> io::Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(length)
            .ok_or_else(|| invalid_graph("graph offset overflow"))?;
        if end > self.bytes.len() {
            return Err(invalid_graph("graph payload is truncated"));
        }
        let bytes = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(bytes)
    }

    fn read_u8(&mut self) -> io::Result<u8> {
        Ok(self.take(1)?[0])
    }

    fn read_u32(&mut self) -> io::Result<u32> {
        let mut bytes = [0_u8; 4];
        bytes.copy_from_slice(self.take(4)?);
        Ok(u32::from_be_bytes(bytes))
    }

    fn read_u64(&mut self) -> io::Result<u64> {
        let mut bytes = [0_u8; 8];
        bytes.copy_from_slice(self.take(8)?);
        Ok(u64::from_be_bytes(bytes))
    }

    fn read_bool(&mut self) -> io::Result<bool> {
        match self.read_u8()? {
            0 => Ok(false),
            1 => Ok(true),
            value => Err(invalid_graph(format!("invalid graph boolean: {value}"))),
        }
    }

    fn read_string(&mut self) -> io::Result<String> {
        let length = self.read_u32()? as usize;
        let bytes = self.take(length)?;
        String::from_utf8(bytes.to_owned())
            .map_err(|_| invalid_graph("graph contains invalid UTF-8"))
    }

    fn read_count(&mut self, label: &str) -> io::Result<usize> {
        let count = self.read_u32()? as usize;
        if count > GRAPH_MAX_COLLECTION_ITEMS {
            return Err(invalid_graph(format!(
                "{label} count exceeds the graph safety limit"
            )));
        }
        Ok(count)
    }

    fn read_strings(&mut self, label: &str) -> io::Result<Vec<String>> {
        let count = self.read_count(label)?;
        (0..count).map(|_| self.read_string()).collect()
    }

    fn read_string_map(&mut self) -> io::Result<BTreeMap<String, String>> {
        let count = self.read_count("string map")?;
        let mut values = BTreeMap::new();
        for _ in 0..count {
            let key = self.read_string()?;
            let value = self.read_string()?;
            if values.insert(key, value).is_some() {
                return Err(invalid_graph("graph contains a duplicate string-map key"));
            }
        }
        Ok(values)
    }

    fn read_api_fingerprints(
        &mut self,
    ) -> io::Result<BTreeMap<String, crate::protocol::ApiFingerprintRecord>> {
        let count = self.read_count("api fingerprints")?;
        let mut values = BTreeMap::new();
        for _ in 0..count {
            let asset = self.read_string()?;
            let digest = self.read_string()?;
            let fingerprint = self.read_string()?;
            let record = crate::protocol::ApiFingerprintRecord {
                digest,
                fingerprint,
            };
            if values.insert(asset, record).is_some() {
                return Err(invalid_graph(
                    "graph contains a duplicate api fingerprint asset",
                ));
            }
        }
        Ok(values)
    }

    /// The schema 9 layout: the bare fingerprint string per asset.
    /// Decoded records carry an empty digest, which never matches a
    /// snapshot digest, so schema 9 evidence stays inert; ordinary
    /// loading invalidates the obsolete schema before use anyway.
    fn read_api_fingerprint_strings(
        &mut self,
    ) -> io::Result<BTreeMap<String, crate::protocol::ApiFingerprintRecord>> {
        let count = self.read_count("api fingerprints")?;
        let mut values = BTreeMap::new();
        for _ in 0..count {
            let asset = self.read_string()?;
            let fingerprint = self.read_string()?;
            let record = crate::protocol::ApiFingerprintRecord {
                digest: String::new(),
                fingerprint,
            };
            if values.insert(asset, record).is_some() {
                return Err(invalid_graph(
                    "graph contains a duplicate api fingerprint asset",
                ));
            }
        }
        Ok(values)
    }

    fn read_snapshot(&mut self) -> io::Result<Snapshot> {
        let count = self.read_count("asset snapshot")?;
        let mut snapshot = BTreeMap::new();
        for _ in 0..count {
            let asset = self.read_string()?;
            let entry = AssetSnapshot {
                exists: self.read_bool()?,
                digest: self.read_string()?,
                size: self.read_u64()?,
            };
            if snapshot.insert(asset, entry).is_some() {
                return Err(invalid_graph("graph contains a duplicate asset key"));
            }
        }
        Ok(snapshot)
    }

    fn read_action(&mut self, schema_version: u32) -> io::Result<ActionState> {
        let shared_part = if self.read_bool()? {
            Some(crate::shared_library::SharedContribution {
                header: self.read_string()?,
                imports: self.read_string()?,
                source: self.read_string()?,
            })
        } else {
            None
        };
        let builder = self.read_string()?;
        let input = self.read_string()?;
        let reads = self.read_strings("action reads")?;
        let resolver_reads = self.read_strings("resolver reads")?;
        let resolver_content_reads = if schema_version >= GRAPH_SCHEMA_API_FINGERPRINTS {
            self.read_strings("resolver content reads")?
        } else {
            Vec::new()
        };
        let resolver_entrypoints = self.read_strings("resolver entrypoints")?;
        let glob_count = self.read_count("glob reads")?;
        let mut glob_reads = Vec::with_capacity(glob_count);
        for _ in 0..glob_count {
            glob_reads.push(GlobRead {
                package: self.read_string()?,
                pattern: self.read_string()?,
            });
        }
        let outputs = self.read_strings("action outputs")?;
        let output_digests = self.read_string_map()?;
        let status = self.read_string()?;
        Ok(ActionState {
            shared_part,
            builder,
            input,
            reads,
            resolver_reads,
            resolver_content_reads,
            resolver_entrypoints,
            glob_reads,
            outputs,
            output_digests,
            status,
        })
    }

    fn read_string_list_map(&mut self) -> io::Result<BTreeMap<String, Vec<String>>> {
        let count = self.read_count("resolver dep graph")?;
        let mut values = BTreeMap::new();
        for _ in 0..count {
            let key = self.read_string()?;
            let value = self.read_strings("resolver dep graph edges")?;
            if values.insert(key, value).is_some() {
                return Err(invalid_graph(
                    "graph contains a duplicate resolver dep graph key",
                ));
            }
        }
        Ok(values)
    }

    /// Decodes all required fields of the current private format.
    fn read_graph_state(&mut self, schema_version: u32) -> io::Result<GraphState> {
        let config_digest = self.read_string()?;
        let was_filtered = self.read_bool()?;
        let assets = self.read_snapshot()?;
        let action_count = self.read_count("action graph")?;
        let mut actions = BTreeMap::new();
        for _ in 0..action_count {
            let key = self.read_string()?;
            let action = self.read_action(schema_version)?;
            if actions.insert(key, action).is_some() {
                return Err(invalid_graph("graph contains a duplicate action key"));
            }
        }
        let resolver_dep_graph = self.read_string_list_map()?;
        let asset_fingerprints = if schema_version >= GRAPH_SCHEMA_API_FINGERPRINT_RECORDS {
            self.read_api_fingerprints()?
        } else if schema_version >= GRAPH_SCHEMA_API_FINGERPRINTS {
            self.read_api_fingerprint_strings()?
        } else {
            BTreeMap::new()
        };
        let mut output_locations = BTreeMap::new();
        let count = self.read_count("output locations")?;
        for _ in 0..count {
            let asset = self.read_string()?;
            let cache = self.read_bool()?;
            if output_locations.insert(asset, cache).is_some() {
                return Err(invalid_graph("graph contains a duplicate output location"));
            }
        }
        let stock_input_order = self.read_string_list_map()?;
        let mut stock_glob_members = BTreeMap::new();
        for _ in 0..self.read_count("stock glob actions")? {
            let key = self.read_string()?;
            let globs = self.read_string_list_map()?;
            if stock_glob_members.insert(key, globs).is_some() {
                return Err(invalid_graph(
                    "graph contains a duplicate stock glob action",
                ));
            }
        }
        let watch_generated_sources = self
            .read_strings("watch generated sources")?
            .into_iter()
            .collect();
        let retained_output_state = self.read_bool()?;
        Ok(GraphState {
            retained_output_state,
            schema_version,
            config_digest,
            was_filtered,
            assets,
            actions,
            resolver_dep_graph,
            asset_fingerprints,
            output_locations,
            stock_input_order,
            stock_glob_members,
            watch_generated_sources,
            api_fingerprint_reports: BTreeSet::new(),
            api_fingerprint_conflicts: BTreeSet::new(),
        })
    }

    /// Rejects trailing bytes so a valid prefix cannot hide an unknown payload.
    fn finish(&self) -> io::Result<()> {
        if self.offset == self.bytes.len() {
            Ok(())
        } else {
            Err(invalid_graph("graph payload contains trailing bytes"))
        }
    }
}
