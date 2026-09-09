use crate::protocol::GlobRead;
use crate::snapshot::{glob_asset_key, AssetSnapshot, Snapshot};
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::Path;

pub const GRAPH_SCHEMA_VERSION: u32 = 3;
const GRAPH_MAGIC: &[u8; 4] = b"BRAG";
const GRAPH_FORMAT_VERSION: u8 = 1;
const GRAPH_HEADER_LENGTH: usize = GRAPH_MAGIC.len() + 1 + 4;
const GRAPH_MAX_BYTES: usize = 256 * 1024 * 1024;
const GRAPH_MAX_COLLECTION_ITEMS: usize = 4_000_000;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ActionState {
    pub builder: String,
    pub input: String,
    pub reads: Vec<String>,
    pub resolver_reads: Vec<String>,
    pub glob_reads: Vec<GlobRead>,
    pub outputs: Vec<String>,
    pub output_digests: BTreeMap<String, String>,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GraphState {
    pub schema_version: u32,
    pub config_digest: String,
    pub assets: Snapshot,
    pub actions: BTreeMap<String, ActionState>,
}

impl GraphState {
    pub fn load(path: &Path) -> io::Result<Self> {
        let contents = match fs::read(path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Self {
                schema_version: GRAPH_SCHEMA_VERSION,
                ..Self::default()
            }),
            Err(error) => return Err(error),
        };
        if contents.len() < GRAPH_HEADER_LENGTH {
            return Err(invalid_graph("graph file is truncated"));
        }
        if contents.len() > GRAPH_HEADER_LENGTH + GRAPH_MAX_BYTES {
            return Err(invalid_graph("graph file exceeds the 256 MiB safety limit"));
        }
        if &contents[..GRAPH_MAGIC.len()] != GRAPH_MAGIC {
            return Err(invalid_graph("graph file has an unknown magic"));
        }
        if contents[GRAPH_MAGIC.len()] != GRAPH_FORMAT_VERSION {
            return Err(invalid_graph("graph file has an unsupported format version"));
        }

        let mut length_bytes = [0_u8; 4];
        length_bytes.copy_from_slice(&contents[GRAPH_MAGIC.len() + 1..GRAPH_HEADER_LENGTH]);
        let payload_length = u32::from_be_bytes(length_bytes) as usize;
        if payload_length != contents.len() - GRAPH_HEADER_LENGTH {
            return Err(invalid_graph("graph payload length does not match file length"));
        }

        let mut decoder = Decoder::new(&contents[GRAPH_HEADER_LENGTH..]);
        let state = decoder.read_graph_state()?;
        decoder.finish()?;
        Ok(state)
    }

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

    pub fn update_metadata_if_changed(
        &mut self,
        config_digest: &str,
        snapshot: Snapshot,
    ) -> bool {
        let changed = self.schema_version != GRAPH_SCHEMA_VERSION
            || self.config_digest != config_digest
            || self.assets != snapshot;
        if changed {
            self.schema_version = GRAPH_SCHEMA_VERSION;
            self.config_digest = config_digest.to_owned();
            self.update_assets(snapshot);
        }
        changed
    }

    pub fn changed_since_previous(
        &self,
        action: &ActionState,
        current_assets: &Snapshot,
        current_output_digests: &BTreeMap<String, String>,
    ) -> bool {
        let mut dependencies = Vec::with_capacity(1 + action.reads.len() + action.resolver_reads.len());
        dependencies.push(action.input.as_str());
        dependencies.extend(action.reads.iter().map(String::as_str));
        dependencies.extend(action.resolver_reads.iter().map(String::as_str));
        dependencies.into_iter().any(|asset| {
            let previous = self
                .assets
                .get(asset)
                .map(|entry| (entry.exists, entry.digest.as_str()));
            let current = current_assets
                .get(asset)
                .map(|entry| (entry.exists, entry.digest.as_str()));
            previous != current
        }) || action.glob_reads.iter().any(|glob| {
            let key = glob_asset_key(glob);
            let previous = self
                .assets
                .get(&key)
                .map(|entry| (entry.exists, entry.digest.as_str()));
            let current = current_assets
                .get(&key)
                .map(|entry| (entry.exists, entry.digest.as_str()));
            previous != current
        }) || action
            .outputs
            .iter()
            .any(|output| action.output_digests.get(output) != current_output_digests.get(output))
    }

    pub fn update_assets(&mut self, snapshot: Snapshot) {
        self.assets = snapshot;
    }

    pub fn is_compatible(&self, config_digest: &str) -> bool {
        self.schema_version == GRAPH_SCHEMA_VERSION && self.config_digest == config_digest
    }
}

fn invalid_graph(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

struct Encoder {
    bytes: Vec<u8>,
}

impl Encoder {
    fn new() -> Self {
        Self { bytes: Vec::new() }
    }

    fn finish(self) -> Vec<u8> {
        self.bytes
    }

    fn append(&mut self, bytes: &[u8]) -> io::Result<()> {
        let new_length = self
            .bytes
            .len()
            .checked_add(bytes.len())
            .ok_or_else(|| invalid_graph("graph payload length overflow"))?;
        if new_length > GRAPH_MAX_BYTES {
            return Err(invalid_graph("graph payload exceeds the 256 MiB safety limit"));
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
        let length = u32::try_from(bytes.len())
            .map_err(|_| invalid_graph("graph string is too large"))?;
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

    fn write_action(&mut self, action: &ActionState) -> io::Result<()> {
        self.write_string(&action.builder)?;
        self.write_string(&action.input)?;
        self.write_strings(&action.reads, "action reads")?;
        self.write_strings(&action.resolver_reads, "resolver reads")?;
        self.write_count(action.glob_reads.len(), "glob reads")?;
        for glob in &action.glob_reads {
            self.write_string(&glob.package)?;
            self.write_string(&glob.pattern)?;
        }
        self.write_strings(&action.outputs, "action outputs")?;
        self.write_string_map(&action.output_digests)?;
        self.write_string(&action.status)
    }

    fn write_graph_state(&mut self, state: &GraphState) -> io::Result<()> {
        self.write_u32(state.schema_version)?;
        self.write_string(&state.config_digest)?;
        self.write_snapshot(&state.assets)?;
        self.write_count(state.actions.len(), "action graph")?;
        for (key, action) in &state.actions {
            self.write_string(key)?;
            self.write_action(action)?;
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

    fn read_action(&mut self) -> io::Result<ActionState> {
        let builder = self.read_string()?;
        let input = self.read_string()?;
        let reads = self.read_strings("action reads")?;
        let resolver_reads = self.read_strings("resolver reads")?;
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
            builder,
            input,
            reads,
            resolver_reads,
            glob_reads,
            outputs,
            output_digests,
            status,
        })
    }

    fn read_graph_state(&mut self) -> io::Result<GraphState> {
        let schema_version = self.read_u32()?;
        let config_digest = self.read_string()?;
        let assets = self.read_snapshot()?;
        let action_count = self.read_count("action graph")?;
        let mut actions = BTreeMap::new();
        for _ in 0..action_count {
            let key = self.read_string()?;
            let action = self.read_action()?;
            if actions.insert(key, action).is_some() {
                return Err(invalid_graph("graph contains a duplicate action key"));
            }
        }
        Ok(GraphState {
            schema_version,
            config_digest,
            assets,
            actions,
        })
    }

    fn finish(&self) -> io::Result<()> {
        if self.offset == self.bytes.len() {
            Ok(())
        } else {
            Err(invalid_graph("graph payload contains trailing bytes"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ActionState, GraphState};
    use crate::protocol::GlobRead;
    use crate::snapshot::{glob_asset_key, AssetSnapshot, Snapshot};
    use std::collections::BTreeMap;

    fn state_with_glob(glob: &GlobRead, digest: &str) -> GraphState {
        let mut assets = Snapshot::new();
        assets.insert(
            glob_asset_key(glob),
            AssetSnapshot {
                exists: true,
                digest: digest.to_owned(),
                size: 0,
            },
        );
        GraphState {
            schema_version: super::GRAPH_SCHEMA_VERSION,
            config_digest: String::new(),
            assets,
            actions: BTreeMap::new(),
        }
    }

    fn action(glob: GlobRead) -> ActionState {
        ActionState {
            builder: "example:combining_builder".to_owned(),
            input: "app|lib/model.dart".to_owned(),
            glob_reads: vec![glob],
            status: "success".to_owned(),
            ..ActionState::default()
        }
    }

    #[test]
    fn glob_membership_change_marks_action_dirty() {
        let glob = GlobRead {
            package: "app".to_owned(),
            pattern: "lib/model.*.part".to_owned(),
        };
        let state = state_with_glob(&glob, "before");
        let mut current = state.assets.clone();
        current
            .get_mut(&glob_asset_key(&glob))
            .expect("glob snapshot")
            .digest = "after".to_owned();

        assert!(state.changed_since_previous(&action(glob), &current, &BTreeMap::new()));
    }

    #[test]
    fn unchanged_glob_does_not_mark_action_dirty() {
        let glob = GlobRead {
            package: "app".to_owned(),
            pattern: "lib/model.*.part".to_owned(),
        };
        let state = state_with_glob(&glob, "same");
        assert!(!state.changed_since_previous(&action(glob), &state.assets, &BTreeMap::new()));
    }

    #[test]
    fn missing_dependency_becoming_present_marks_action_dirty() {
        let dependency = "app|lib/conditional.dart".to_owned();
        let mut assets = Snapshot::new();
        assets.insert(
            dependency.clone(),
            AssetSnapshot {
                exists: false,
                digest: "<missing>".to_owned(),
                size: 0,
            },
        );
        let state = GraphState {
            schema_version: super::GRAPH_SCHEMA_VERSION,
            assets,
            ..GraphState::default()
        };
        let action = ActionState {
            builder: "example:builder".to_owned(),
            input: "app|lib/model.dart".to_owned(),
            resolver_reads: vec![dependency.clone()],
            status: "success".to_owned(),
            ..ActionState::default()
        };
        let mut current = state.assets.clone();
        current.insert(
            dependency,
            AssetSnapshot {
                exists: true,
                digest: "actual".to_owned(),
                size: 1,
            },
        );

        assert!(state.changed_since_previous(&action, &current, &BTreeMap::new()));
    }

    #[test]
    fn old_graph_schema_is_not_compatible() {
        let state = GraphState {
            schema_version: 1,
            config_digest: "same".to_owned(),
            ..GraphState::default()
        };
        assert!(!state.is_compatible("same"));
    }

    #[test]
    fn binary_graph_round_trip_preserves_state() {
        let state = GraphState {
            schema_version: super::GRAPH_SCHEMA_VERSION,
            config_digest: "config".to_owned(),
            assets: Snapshot::from([(
                "app|lib/model.dart".to_owned(),
                AssetSnapshot {
                    exists: true,
                    digest: "asset-digest".to_owned(),
                    size: 12,
                },
            )]),
            actions: BTreeMap::from([(
                "example:builder|app|lib/model.dart".to_owned(),
                ActionState {
                    builder: "example:builder".to_owned(),
                    input: "app|lib/model.dart".to_owned(),
                    reads: vec!["app|lib/model.dart".to_owned()],
                    resolver_reads: vec!["app|lib/conditional.dart".to_owned()],
                    glob_reads: vec![GlobRead {
                        package: "app".to_owned(),
                        pattern: "lib/*.part".to_owned(),
                    }],
                    outputs: vec!["app|lib/model.g.dart".to_owned()],
                    output_digests: BTreeMap::from([(
                        "app|lib/model.g.dart".to_owned(),
                        "output-digest".to_owned(),
                    )]),
                    status: "success".to_owned(),
                },
            )]),
        };
        let unique = format!(
            "build-runner-accelerator-graph-{}-{}.bin",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock")
                .as_nanos()
        );
        let path = std::env::temp_dir().join(unique);

        state.save(&path).expect("save graph");
        let bytes = std::fs::read(&path).expect("read graph");
        assert_eq!(&bytes[..super::GRAPH_MAGIC.len()], super::GRAPH_MAGIC);
        assert_eq!(bytes[super::GRAPH_MAGIC.len()], super::GRAPH_FORMAT_VERSION);
        assert_eq!(GraphState::load(&path).expect("load graph"), state);

        std::fs::remove_file(path).expect("remove graph");
    }

    #[test]
    fn graph_requires_binary_header() {
        let unique = format!(
            "build-runner-accelerator-invalid-{}-{}.bin",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock")
                .as_nanos()
        );
        let path = std::env::temp_dir().join(unique);
        std::fs::write(&path, b"{}\n").expect("write invalid graph");

        let error = GraphState::load(&path).expect_err("invalid graph should fail");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);

        std::fs::remove_file(path).expect("remove invalid graph");
    }

    #[test]
    fn unchanged_metadata_does_not_require_persist() {
        let assets = Snapshot::new();
        let mut state = GraphState {
            schema_version: super::GRAPH_SCHEMA_VERSION,
            config_digest: "same".to_owned(),
            assets: assets.clone(),
            ..GraphState::default()
        };

        assert!(!state.update_metadata_if_changed("same", assets));
    }

    #[test]
    fn changed_metadata_is_applied_and_requires_persist() {
        let mut state = GraphState {
            schema_version: 1,
            config_digest: "old".to_owned(),
            ..GraphState::default()
        };
        let mut assets = Snapshot::new();
        assets.insert(
            "app|lib/model.dart".to_owned(),
            AssetSnapshot {
                exists: true,
                digest: "digest".to_owned(),
                size: 6,
            },
        );

        assert!(state.update_metadata_if_changed("new", assets.clone()));
        assert_eq!(state.schema_version, super::GRAPH_SCHEMA_VERSION);
        assert_eq!(state.config_digest, "new");
        assert_eq!(state.assets, assets);
    }
}
