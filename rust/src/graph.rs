use crate::protocol::GlobRead;
use crate::snapshot::{AssetSnapshot, Snapshot, glob_asset_key};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::Path;

pub const GRAPH_SCHEMA_VERSION: u32 = 10;

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
const GRAPH_MAGIC: &[u8; 4] = b"BRAG";
const GRAPH_FORMAT_VERSION: u8 = 3;
const GRAPH_HEADER_LENGTH: usize = GRAPH_MAGIC.len() + 1 + 4;
const GRAPH_MAX_BYTES: usize = 256 * 1024 * 1024;
const GRAPH_MAX_COLLECTION_ITEMS: usize = 4_000_000;

/// Persisted observations for one builder action, used to decide reuse and
/// retain the actual output set from its last successful execution.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ActionState {
    pub shared_part: Option<crate::shared_library::SharedContribution>,
    pub builder: String,
    pub input: String,
    pub reads: Vec<String>,
    pub resolver_reads: Vec<String>,
    /// Libraries the action touched as source text through the
    /// resolver (ADR 0056): actions with a non-empty split observe
    /// more than the API fingerprint covers, so later stages key
    /// their resolver reads by content instead of by signature.
    pub resolver_content_reads: Vec<String>,
    /// Entrypoints the action passed to the resolver. Dependency edges are
    /// expanded through [`GraphState::resolver_dep_graph`] at dirty-check
    /// time, mirroring stock build_runner's `previousLibraryCycleGraphLoader`.
    pub resolver_entrypoints: Vec<String>,
    pub glob_reads: Vec<GlobRead>,
    pub outputs: Vec<String>,
    pub output_digests: BTreeMap<String, String>,
    pub status: String,
}

/// Incremental evidence committed after a successful build. In particular,
/// `output_locations` records where outputs were actually written, rather than
/// guessing from whichever path currently exists.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GraphState {
    pub schema_version: u32,
    pub config_digest: String,
    /// Whether the last successful build applied output filters.
    pub was_filtered: bool,
    pub assets: Snapshot,
    pub actions: BTreeMap<String, ActionState>,
    /// Direct dependency edges the Dart resolver loader has observed.
    /// Actions that resolve an already-loaded library cycle observe no new
    /// IO, so their dependency edges cannot be recovered from reads alone.
    pub resolver_dep_graph: BTreeMap<String, Vec<String>>,
    /// API fingerprints of source units, learned by the workers' dep
    /// walks (ADR 0056), each bound to the content digest that
    /// produced it. Absence means no evidence: later stages treat
    /// such units as content-keyed.
    pub asset_fingerprints: BTreeMap<String, crate::protocol::ApiFingerprintRecord>,
    /// Assets whose fingerprint the current build reported, used by
    /// [`GraphState::update_assets`] to tell fresh evidence apart from
    /// records the previous build left. Runtime-only: never saved.
    pub api_fingerprint_reports: BTreeSet<String>,
    /// Assets whose fingerprint reports conflicted within the current
    /// build (learned from different bytes after a mid-build edit).
    /// Their evidence stays dropped until the next build boundary:
    /// no later report in the same build can resurrect it, because
    /// outputs may have been generated against either observation.
    /// Runtime-only: never saved.
    pub api_fingerprint_conflicts: BTreeSet<String>,
    /// Actual output location at the successful commit (true means cache).
    pub output_locations: BTreeMap<String, bool>,
    /// Stock InputTracker input order, distinct from broader observed reads.
    pub stock_input_order: BTreeMap<String, Vec<String>>,
    /// Actual glob results by action and glob, preserving source/generated order.
    pub stock_glob_members: BTreeMap<String, BTreeMap<String, Vec<String>>>,
    /// Source-path generated files excluded from plain sources in this watch.
    pub watch_generated_sources: BTreeSet<String>,
    /// A keep build can leave consumers generated from retained manual bytes.
    /// Subsequent overwrite builds must keep using demand evaluation, even
    /// after upstream files are repaired: equal logical producer bytes must
    /// not cause those legitimate consumers to rerun through eager invalidation.
    pub retained_output_state: bool,
}

impl GraphState {
    /// Reports a cycle in the recorded resolver dependency edges.
    /// Missing leaf nodes are included as ordinary vertices; the check is
    /// based on recorded resolver evidence, not action-graph dependencies.
    pub(crate) fn has_resolver_cycle(&self) -> bool {
        let mut degrees = BTreeMap::new();
        for (asset, edges) in &self.resolver_dep_graph {
            degrees.entry(asset.as_str()).or_insert(0usize);
            for edge in edges {
                *degrees.entry(edge.as_str()).or_insert(0) += 1;
            }
        }
        let mut ready: Vec<_> = degrees
            .iter()
            .filter(|(_, degree)| **degree == 0)
            .map(|(asset, _)| *asset)
            .collect();
        let mut processed = 0;
        while let Some(asset) = ready.pop() {
            processed += 1;
            if let Some(edges) = self.resolver_dep_graph.get(asset) {
                for edge in edges {
                    let degree = degrees.get_mut(edge.as_str()).expect("edge was indexed");
                    *degree -= 1;
                    if *degree == 0 {
                        ready.push(edge.as_str());
                    }
                }
            }
        }
        processed != degrees.len()
    }

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
    fn load_checked(path: &Path) -> io::Result<Self> {
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

    /// Merges API fingerprints reported by the workers (ADR 0056). A
    /// reported record replaces the recorded one; a reported
    /// unavailable marker removes the entry, so evidence recorded for
    /// an earlier content of the asset is never kept.
    /// Drops the recorded fingerprints of [assets], whose bytes a
    /// resolver reset is changing. Called by the frontend before
    /// post-reset actions dispatch, so a removal can never merge
    /// after a fingerprint relearned from the new bytes.
    pub fn drop_api_fingerprints(&mut self, assets: &BTreeSet<String>) {
        for asset in assets {
            self.asset_fingerprints.remove(asset);
        }
    }

    pub fn merge_api_fingerprints(
        &mut self,
        reported: BTreeMap<String, Option<crate::protocol::ApiFingerprintRecord>>,
    ) {
        for (asset, record) in reported {
            if self.api_fingerprint_conflicts.contains(&asset) {
                self.asset_fingerprints.remove(&asset);
                continue;
            }
            match record {
                Some(record) => {
                    // A second, different report for the same asset in
                    // one build means the build observed two versions
                    // of its bytes (a mid-build edit): outputs may
                    // have been generated against either fingerprint,
                    // so the evidence is dropped for the rest of the
                    // build rather than letting the later report win.
                    if self.api_fingerprint_reports.contains(&asset)
                        && self.asset_fingerprints.get(&asset) != Some(&record)
                    {
                        self.asset_fingerprints.remove(&asset);
                        self.api_fingerprint_conflicts.insert(asset);
                        continue;
                    }
                    self.api_fingerprint_reports.insert(asset.clone());
                    self.asset_fingerprints.insert(asset, record);
                }
                None => {
                    // An unavailable report after a recorded one in
                    // the same build is a disagreement too: the two
                    // observations cannot both describe the bytes the
                    // build's outputs were generated against, so the
                    // evidence stays dropped for the rest of the
                    // build instead of being resurrected by a later
                    // agreeing report.
                    if self.api_fingerprint_reports.contains(&asset) {
                        self.api_fingerprint_conflicts.insert(asset.clone());
                    }
                    self.asset_fingerprints.remove(&asset);
                    self.api_fingerprint_reports.insert(asset);
                }
            }
        }
    }

    /// Updates compatibility metadata and the filesystem snapshot together.
    /// Returns true exactly when the persisted graph now needs a save.
    pub fn update_metadata_if_changed(&mut self, config_digest: &str, snapshot: Snapshot) -> bool {
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

    /// Precomputed change information shared by every per-action dirty
    /// check: the assets whose snapshot entry differs between the previous
    /// and current runs, plus the reverse closure of that set through
    /// [`GraphState::resolver_dep_graph`]. An entrypoint in `tainted` means
    /// something it transitively depends on changed, which is exactly what
    /// expanding `action_entrypoint_deps` per action was checking — once
    /// instead of per action.
    pub fn dirty_context<'a>(&'a self, current_assets: &'a Snapshot) -> DirtyContext<'a> {
        let mut changed = std::collections::HashSet::new();
        // Both snapshots are ordered. Merge them once instead of searching
        // either tree for every asset; additions and removals are changes too.
        let mut previous = self.assets.iter().peekable();
        let mut current = current_assets.iter().peekable();
        while let (Some((old_asset, old)), Some((new_asset, new))) =
            (previous.peek(), current.peek())
        {
            match old_asset.cmp(new_asset) {
                std::cmp::Ordering::Less => {
                    changed.insert(old_asset.as_str());
                    previous.next();
                }
                std::cmp::Ordering::Greater => {
                    changed.insert(new_asset.as_str());
                    current.next();
                }
                std::cmp::Ordering::Equal => {
                    if old.exists != new.exists || old.digest != new.digest {
                        changed.insert(old_asset.as_str());
                    }
                    previous.next();
                    current.next();
                }
            }
        }
        changed.extend(previous.map(|(asset, _)| asset.as_str()));
        changed.extend(current.map(|(asset, _)| asset.as_str()));
        // The reverse closure of an empty change set is empty. In particular,
        // no-op builds need no reverse-edge map or per-node Vec allocations.
        if changed.is_empty() {
            return DirtyContext {
                changed,
                tainted: std::collections::HashSet::new(),
            };
        }
        let mut parents: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
        for (node, deps) in &self.resolver_dep_graph {
            for dep in deps {
                parents.entry(dep.as_str()).or_default().push(node.as_str());
            }
        }
        let mut tainted = std::collections::HashSet::new();
        let mut stack: Vec<&str> = changed.iter().copied().collect();
        while let Some(asset) = stack.pop() {
            if !tainted.insert(asset) {
                continue;
            }
            if let Some(dependents) = parents.get(asset) {
                stack.extend(dependents.iter().copied());
            }
        }
        DirtyContext { changed, tainted }
    }

    #[cfg(test)]
    pub fn changed_since_previous(
        &self,
        action: &ActionState,
        current_assets: &Snapshot,
        current_output_digests: &BTreeMap<String, String>,
    ) -> bool {
        let context = self.dirty_context(current_assets);
        self.changed_since_previous_with(
            action,
            &context,
            current_assets,
            current_output_digests,
            false,
        )
    }

    /// Compares a recorded action with the old/current snapshots and the
    /// precomputed resolver closure. Reads and input are compared by presence
    /// and digest, glob dependencies by membership snapshot, and outputs by
    /// recorded/current output digest; any difference requires execution.
    pub fn changed_since_previous_with(
        &self,
        action: &ActionState,
        context: &DirtyContext<'_>,
        current_assets: &Snapshot,
        current_output_digests: &BTreeMap<String, String>,
        resolver_explained: bool,
    ) -> bool {
        // The primary input and direct reads are content observations:
        // they always key the action. Resolver observations are keyed
        // by content too, unless `resolver_explained` reports that the
        // action's effective API signature is unchanged (ADR 0056), in
        // which case they cannot have observed anything new.
        let direct_changed = std::iter::once(action.input.as_str())
            .chain(action.reads.iter().map(String::as_str))
            .any(|asset| context.changed.contains(asset));
        let resolver_changed = action
            .resolver_reads
            .iter()
            .any(|asset| context.changed.contains(asset.as_str()))
            || action
                .resolver_entrypoints
                .iter()
                .any(|entrypoint| context.tainted.contains(entrypoint.as_str()));
        direct_changed
            || (resolver_changed && !resolver_explained)
            || action.glob_reads.iter().any(|glob| {
                let key = glob_asset_key(glob);
                let previous = self
                    .assets
                    .get(&key)
                    .map(|entry| (entry.exists, entry.digest.as_str()));
                let current = current_assets
                    .get(&key)
                    .map(|entry| (entry.exists, entry.digest.as_str()));
                previous != current
            })
            || action.outputs.iter().any(|output| {
                action.output_digests.get(output) != current_output_digests.get(output)
            })
    }

    pub fn update_assets(&mut self, snapshot: Snapshot) {
        // A recorded fingerprint describes the bytes it was learned
        // from. An asset whose snapshot entry changed or vanished
        // since the previous build drops its fingerprint here, at
        // the build boundary, so a build that never relearns it (for
        // example because only opted-out actions resolved it) cannot
        // leave evidence for superseded bytes behind. Fingerprints
        // reported during this build are fresh evidence and survive
        // even when their asset changed.
        if !self.asset_fingerprints.is_empty() {
            let reported = &self.api_fingerprint_reports;
            self.asset_fingerprints.retain(|asset, _| {
                (reported.contains(asset) && snapshot.get(asset).is_some_and(|entry| entry.exists))
                    || match (self.assets.get(asset), snapshot.get(asset)) {
                        (Some(old), Some(new)) => {
                            old.exists == new.exists && old.digest == new.digest
                        }
                        _ => false,
                    }
            });
        }
        self.api_fingerprint_reports.clear();
        self.api_fingerprint_conflicts.clear();
        self.assets = snapshot;
    }

    /// Drops the fingerprints reported this build for assets whose
    /// bytes the build's transaction changed after a walk could have
    /// fingerprinted them (an output written or deleted later in the
    /// build, a source edit published at commit). A report cannot say
    /// which in-build version of the bytes it describes, and the
    /// previous-vs-final comparison in [`GraphState::update_assets`]
    /// cannot detect every stale value (a transaction that restores
    /// the previous bytes leaves the two snapshots equal), so the
    /// values are removed outright rather than only losing their
    /// fresh-evidence exemption.
    pub fn supersede_api_fingerprint_reports(&mut self, assets: &BTreeSet<String>) {
        for asset in assets {
            self.api_fingerprint_reports.remove(asset);
            self.api_fingerprint_conflicts.remove(asset);
            self.asset_fingerprints.remove(asset);
        }
    }

    /// Whether this graph's schema and builder configuration match the plan.
    /// A false result means prior action/output evidence cannot authorize reuse.
    pub fn is_compatible(&self, config_digest: &str) -> bool {
        self.schema_version == GRAPH_SCHEMA_VERSION && self.config_digest == config_digest
    }
}

fn invalid_graph(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

/// Shared per-pass dirty-check state: `changed` holds the assets whose
/// snapshot entry differs between the previous and current runs, and
/// `tainted` is the reverse closure of `changed` through the resolver
/// dependency graph (assets that transitively depend on a changed one).
pub struct DirtyContext<'a> {
    changed: std::collections::HashSet<&'a str>,
    tainted: std::collections::HashSet<&'a str>,
}

impl DirtyContext<'_> {
    /// Assets whose snapshot entry differs (see [`GraphState::dirty_context`]).
    pub fn changed(&self) -> &std::collections::HashSet<&str> {
        &self.changed
    }

    /// Assets whose resolver dependency closure contains a changed asset.
    pub fn tainted(&self) -> &std::collections::HashSet<&str> {
        &self.tainted
    }
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

    fn write_graph_state(&mut self, state: &GraphState) -> io::Result<()> {
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

#[cfg(test)]
#[path = "graph_bench.rs"]
mod bench;

#[cfg(test)]
mod tests {
    #[test]
    fn dirty_context_handles_unchanged_cycles_and_snapshot_changes() {
        let mut state = super::GraphState::default();
        for asset in ["a", "b", "c"] {
            state.assets.insert(
                asset.to_owned(),
                crate::snapshot::AssetSnapshot {
                    exists: true,
                    digest: "original".to_owned(),
                    size: 1,
                },
            );
        }
        state.resolver_dep_graph = std::collections::BTreeMap::from([
            ("a".to_owned(), vec!["b".to_owned()]),
            (
                "b".to_owned(),
                vec!["a".to_owned(), "c".to_owned(), "missing".to_owned()],
            ),
        ]);
        let mut current = state.assets.clone();
        // Size is not dirty evidence: keep the presence/digest contract.
        current.get_mut("a").unwrap().size = 99;
        let context = state.dirty_context(&current);
        assert!(context.changed.is_empty());
        assert!(context.tainted.is_empty());
        for case in ["digest", "exists", "removed", "added"] {
            let mut current = state.assets.clone();
            let changed = match case {
                "digest" => {
                    current.get_mut("c").unwrap().digest.push('!');
                    "c"
                }
                "exists" => {
                    current.get_mut("c").unwrap().exists = false;
                    "c"
                }
                "removed" => {
                    current.remove("c");
                    "c"
                }
                _ => {
                    current.insert("missing".to_owned(), state.assets["c"].clone());
                    "missing"
                }
            };
            let context = state.dirty_context(&current);
            assert_eq!(
                context.changed,
                std::collections::HashSet::from([changed]),
                "{case}"
            );
            assert_eq!(
                context.tainted,
                std::collections::HashSet::from([changed, "a", "b"]),
                "{case}"
            );
        }
    }

    #[test]
    fn dirty_context_matches_lookup_reference_for_interleaved_snapshots() {
        // Every key is absent, missing, or present in each snapshot. Exhaustive
        // pairs cover empty maps, additions/removals at both tails and in the
        // middle, and equal IDs with different existence or content evidence.
        fn snapshot(mut pattern: usize, newer: bool) -> super::Snapshot {
            let mut result = super::Snapshot::new();
            for key in ["a", "b", "c", "d"] {
                match pattern % 3 {
                    0 => {}
                    state => {
                        result.insert(
                            key.to_owned(),
                            super::AssetSnapshot {
                                exists: state == 2,
                                digest: if newer && key == "b" { "new" } else { "old" }.into(),
                                size: u64::from(newer),
                            },
                        );
                    }
                }
                pattern /= 3;
            }
            result
        }
        for previous in 0..81 {
            let state = super::GraphState {
                assets: snapshot(previous, false),
                // Duplicate edges, a cycle, and an absent dependency must not
                // alter the reverse closure or make its traversal unbounded.
                resolver_dep_graph: std::collections::BTreeMap::from([
                    ("a".into(), vec!["b".into(), "b".into()]),
                    ("b".into(), vec!["a".into(), "c".into()]),
                    ("c".into(), vec!["d".into(), "missing".into()]),
                ]),
                ..Default::default()
            };
            for next in 0..81 {
                let current = snapshot(next, true);
                let expected: std::collections::HashSet<_> = state
                    .assets
                    .keys()
                    .chain(current.keys())
                    .filter(|key| {
                        let evidence = |entry: Option<&super::AssetSnapshot>| {
                            entry.map(|entry| (entry.exists, entry.digest.clone()))
                        };
                        evidence(state.assets.get(*key)) != evidence(current.get(*key))
                    })
                    .map(String::as_str)
                    .collect();
                let mut tainted = expected.clone();
                loop {
                    let before = tainted.len();
                    for (node, deps) in &state.resolver_dep_graph {
                        if deps.iter().any(|dep| tainted.contains(dep.as_str())) {
                            tainted.insert(node.as_str());
                        }
                    }
                    if tainted.len() == before {
                        break;
                    }
                }
                let actual = state.dirty_context(&current);
                assert_eq!(actual.changed, expected, "{previous}/{next}");
                assert_eq!(actual.tainted, tainted, "{previous}/{next}");
            }
        }
    }

    #[test]
    fn resolver_cycle_detection_handles_shared_children_and_missing_leaves() {
        let mut state = super::GraphState {
            resolver_dep_graph: std::collections::BTreeMap::from([
                ("a".to_owned(), vec!["c".to_owned()]),
                ("b".to_owned(), vec!["c".to_owned()]),
                ("c".to_owned(), vec!["leaf".to_owned()]),
            ]),
            ..super::GraphState::default()
        };
        assert!(!state.has_resolver_cycle());
        state
            .resolver_dep_graph
            .insert("leaf".to_owned(), vec!["a".to_owned()]);
        assert!(state.has_resolver_cycle());
    }
    use super::{ActionState, GraphState};
    use crate::protocol::GlobRead;
    use crate::snapshot::{AssetSnapshot, Snapshot, glob_asset_key};
    use std::collections::{BTreeMap, BTreeSet};

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
            was_filtered: false,
            api_fingerprint_reports: BTreeSet::new(),
            api_fingerprint_conflicts: BTreeSet::new(),
            assets,
            actions: BTreeMap::new(),
            resolver_dep_graph: BTreeMap::new(),
            asset_fingerprints: BTreeMap::new(),
            output_locations: BTreeMap::new(),
            stock_input_order: BTreeMap::new(),
            stock_glob_members: BTreeMap::new(),
            watch_generated_sources: BTreeSet::new(),
            retained_output_state: false,
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
    fn schema_8_graph_body_decodes_for_recovery_validation() {
        // A journal written by the schema 8 binary lacks the schema 9
        // fields. Publication recovery validates that body with
        // decode_checked(.., false) before ordinary load invalidation
        // can run, so it must decode with its own layout.
        let previous = GraphState {
            schema_version: 8,
            config_digest: "previous configuration".to_owned(),
            asset_fingerprints: BTreeMap::from([(
                "app|lib/model.dart".to_owned(),
                crate::protocol::ApiFingerprintRecord {
                    digest: "digest".to_owned(),
                    fingerprint: "fingerprint".to_owned(),
                },
            )]),
            actions: BTreeMap::from([(
                "step".to_owned(),
                ActionState {
                    resolver_content_reads: vec!["app|lib/dep.dart".to_owned()],
                    ..ActionState::default()
                },
            )]),
            ..GraphState::default()
        };
        let mut encoder = super::Encoder::new();
        encoder.write_graph_state(&previous).unwrap();
        let payload = encoder.finish();
        let mut bytes = super::GRAPH_MAGIC.to_vec();
        bytes.push(super::GRAPH_FORMAT_VERSION);
        bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&payload);
        let decoded = GraphState::decode_checked(&bytes, false).unwrap();
        assert_eq!(decoded.config_digest, "previous configuration");
        assert!(decoded.asset_fingerprints.is_empty());
        assert!(decoded.actions["step"].resolver_content_reads.is_empty());
    }

    #[test]
    fn schema_9_graph_body_decodes_for_recovery_validation() {
        // A journal written by the schema 9 binary stores bare
        // fingerprint strings and already has resolver content
        // reads. Publication recovery validates that body with
        // decode_checked(.., false) before ordinary load
        // invalidation can run, so it must decode with its own
        // layout; the fingerprints come back with an empty digest,
        // which no snapshot digest can match.
        let previous = GraphState {
            schema_version: 9,
            config_digest: "previous configuration".to_owned(),
            asset_fingerprints: BTreeMap::from([(
                "app|lib/model.dart".to_owned(),
                crate::protocol::ApiFingerprintRecord {
                    digest: "digest".to_owned(),
                    fingerprint: "fingerprint".to_owned(),
                },
            )]),
            actions: BTreeMap::from([(
                "step".to_owned(),
                ActionState {
                    resolver_content_reads: vec!["app|lib/dep.dart".to_owned()],
                    ..ActionState::default()
                },
            )]),
            ..GraphState::default()
        };
        let mut encoder = super::Encoder::new();
        encoder.write_graph_state(&previous).unwrap();
        let payload = encoder.finish();
        let mut bytes = super::GRAPH_MAGIC.to_vec();
        bytes.push(super::GRAPH_FORMAT_VERSION);
        bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&payload);
        let decoded = GraphState::decode_checked(&bytes, false).unwrap();
        assert_eq!(decoded.config_digest, "previous configuration");
        assert_eq!(
            decoded.asset_fingerprints["app|lib/model.dart"],
            crate::protocol::ApiFingerprintRecord {
                digest: String::new(),
                fingerprint: "fingerprint".to_owned(),
            }
        );
        assert_eq!(
            decoded.actions["step"].resolver_content_reads,
            vec!["app|lib/dep.dart".to_owned()]
        );
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
            was_filtered: true,
            api_fingerprint_reports: BTreeSet::new(),
            api_fingerprint_conflicts: BTreeSet::new(),
            retained_output_state: true,
            watch_generated_sources: BTreeSet::from(["app|lib/omitted.mid".to_owned()]),
            stock_glob_members: BTreeMap::from([(
                "step".to_owned(),
                BTreeMap::from([(
                    "app|lib/*.dart".to_owned(),
                    vec![
                        "app|lib/source.dart".to_owned(),
                        "app|lib/generated.dart".to_owned(),
                    ],
                )]),
            )]),
            stock_input_order: BTreeMap::from([(
                "step".to_owned(),
                vec!["app|lib/b.dart".to_owned(), "app|lib/a.dart".to_owned()],
            )]),
            output_locations: BTreeMap::from([("app|lib/model.g.dart".to_owned(), true)]),
            assets: Snapshot::from([(
                "app|lib/model.dart".to_owned(),
                AssetSnapshot {
                    exists: true,
                    digest: "asset-digest".to_owned(),
                    size: 12,
                },
            )]),
            resolver_dep_graph: BTreeMap::from([(
                "app|lib/model.dart".to_owned(),
                vec!["app|lib/conditional.dart".to_owned()],
            )]),
            asset_fingerprints: BTreeMap::from([(
                "app|lib/model.dart".to_owned(),
                crate::protocol::ApiFingerprintRecord {
                    digest: "digest".to_owned(),
                    fingerprint: "fingerprint".to_owned(),
                },
            )]),
            actions: BTreeMap::from([(
                "example:builder|app|lib/model.dart".to_owned(),
                ActionState {
                    shared_part: Some(crate::shared_library::SharedContribution {
                        header: "// dart format off\npart of '../model.dart';\n\n".into(),
                        imports: "// === example:builder imports.\nimport 'dart:math' as i0;\n\n"
                            .into(),
                        source: "// === example:builder contribution.\nclass Generated {}\n\n"
                            .into(),
                    }),
                    builder: "example:builder".to_owned(),
                    input: "app|lib/model.dart".to_owned(),
                    reads: vec!["app|lib/model.dart".to_owned()],
                    resolver_reads: vec!["app|lib/conditional.dart".to_owned()],
                    resolver_content_reads: vec!["app|lib/other.dart".to_owned()],
                    resolver_entrypoints: vec!["app|lib/model.dart".to_owned()],
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
    fn merge_api_fingerprints_replaces_and_removes() {
        fn record(digest: &str, fingerprint: &str) -> crate::protocol::ApiFingerprintRecord {
            crate::protocol::ApiFingerprintRecord {
                digest: digest.to_owned(),
                fingerprint: fingerprint.to_owned(),
            }
        }
        let mut state = GraphState {
            asset_fingerprints: BTreeMap::from([
                ("app|lib/a.dart".to_owned(), record("d-old", "old")),
                ("app|lib/b.dart".to_owned(), record("d-b", "kept")),
            ]),
            ..GraphState::default()
        };
        state.merge_api_fingerprints(BTreeMap::from([
            ("app|lib/a.dart".to_owned(), Some(record("d-new", "new"))),
            ("app|lib/b.dart".to_owned(), None),
            ("app|lib/c.dart".to_owned(), Some(record("d-c", "added"))),
            ("app|lib/d.dart".to_owned(), None),
        ]));
        assert_eq!(
            state.asset_fingerprints,
            BTreeMap::from([
                ("app|lib/a.dart".to_owned(), record("d-new", "new")),
                ("app|lib/c.dart".to_owned(), record("d-c", "added")),
            ])
        );
    }

    #[test]
    fn merge_api_fingerprints_drops_conflicting_reports_for_the_build() {
        fn record(digest: &str, fingerprint: &str) -> crate::protocol::ApiFingerprintRecord {
            crate::protocol::ApiFingerprintRecord {
                digest: digest.to_owned(),
                fingerprint: fingerprint.to_owned(),
            }
        }
        let mut state = GraphState::default();
        // Two workers observe the same asset at different bytes after
        // a mid-build edit: neither report can be trusted as the
        // basis for the build's outputs, so the evidence is dropped.
        state.merge_api_fingerprints(BTreeMap::from([(
            "app|lib/a.dart".to_owned(),
            Some(record("d-1", "f-1")),
        )]));
        state.merge_api_fingerprints(BTreeMap::from([(
            "app|lib/a.dart".to_owned(),
            Some(record("d-2", "f-2")),
        )]));
        assert!(!state.asset_fingerprints.contains_key("app|lib/a.dart"));
        // A later report in the same build cannot resurrect it, even
        // one that agrees with the first observation.
        state.merge_api_fingerprints(BTreeMap::from([(
            "app|lib/a.dart".to_owned(),
            Some(record("d-1", "f-1")),
        )]));
        assert!(!state.asset_fingerprints.contains_key("app|lib/a.dart"));
        // An unavailable report after a recorded one is a
        // disagreement too, and a later agreeing report cannot
        // resurrect the evidence within the build.
        state.merge_api_fingerprints(BTreeMap::from([(
            "app|lib/c.dart".to_owned(),
            Some(record("d-c", "f-c")),
        )]));
        state.merge_api_fingerprints(BTreeMap::from([("app|lib/c.dart".to_owned(), None)]));
        state.merge_api_fingerprints(BTreeMap::from([(
            "app|lib/c.dart".to_owned(),
            Some(record("d-c", "f-c")),
        )]));
        assert!(!state.asset_fingerprints.contains_key("app|lib/c.dart"));
        // Agreeing reports are kept, and the next build boundary
        // clears the conflict so fresh evidence counts again.
        state.merge_api_fingerprints(BTreeMap::from([(
            "app|lib/b.dart".to_owned(),
            Some(record("d-b", "f-b")),
        )]));
        state.merge_api_fingerprints(BTreeMap::from([(
            "app|lib/b.dart".to_owned(),
            Some(record("d-b", "f-b")),
        )]));
        assert_eq!(
            state.asset_fingerprints.get("app|lib/b.dart"),
            Some(&record("d-b", "f-b"))
        );
        state.update_assets(BTreeMap::from([(
            "app|lib/a.dart".to_owned(),
            crate::snapshot::AssetSnapshot {
                exists: true,
                digest: "d-1".to_owned(),
                size: 1,
            },
        )]));
        assert!(state.api_fingerprint_conflicts.is_empty());
        state.merge_api_fingerprints(BTreeMap::from([(
            "app|lib/a.dart".to_owned(),
            Some(record("d-1", "f-1")),
        )]));
        assert_eq!(
            state.asset_fingerprints.get("app|lib/a.dart"),
            Some(&record("d-1", "f-1"))
        );
    }

    #[test]
    fn update_assets_drops_fingerprints_of_changed_and_removed_assets() {
        let entry = |digest: &str| crate::snapshot::AssetSnapshot {
            exists: true,
            digest: digest.to_owned(),
            size: 1,
        };
        let record = |fingerprint: &str| crate::protocol::ApiFingerprintRecord {
            digest: format!("d-{fingerprint}"),
            fingerprint: fingerprint.to_owned(),
        };
        let mut state = GraphState {
            assets: BTreeMap::from([
                ("app|lib/a.dart".to_owned(), entry("aaa")),
                ("app|lib/b.dart".to_owned(), entry("bbb")),
                ("app|lib/c.dart".to_owned(), entry("ccc")),
            ]),
            asset_fingerprints: BTreeMap::from([
                ("app|lib/a.dart".to_owned(), record("fa")),
                ("app|lib/b.dart".to_owned(), record("fb")),
                ("app|lib/c.dart".to_owned(), record("fc")),
            ]),
            ..GraphState::default()
        };
        state.update_assets(BTreeMap::from([
            ("app|lib/a.dart".to_owned(), entry("aaa")),
            ("app|lib/b.dart".to_owned(), entry("changed")),
        ]));
        assert_eq!(
            state.asset_fingerprints,
            BTreeMap::from([("app|lib/a.dart".to_owned(), record("fa"))])
        );
    }

    #[test]
    fn superseded_or_deleted_reports_are_dropped() {
        let entry = |digest: &str| crate::snapshot::AssetSnapshot {
            exists: true,
            digest: digest.to_owned(),
            size: 1,
        };
        let record = |fingerprint: &str| crate::protocol::ApiFingerprintRecord {
            digest: format!("d-{fingerprint}"),
            fingerprint: fingerprint.to_owned(),
        };
        let mut state = GraphState {
            assets: BTreeMap::from([
                ("app|lib/a.dart".to_owned(), entry("aaa")),
                ("app|lib/gone.dart".to_owned(), entry("ggg")),
                ("app|lib/restored.dart".to_owned(), entry("rrr")),
            ]),
            ..GraphState::default()
        };
        state.merge_api_fingerprints(BTreeMap::from([
            ("app|lib/a.dart".to_owned(), Some(record("fresh-a"))),
            ("app|lib/gone.dart".to_owned(), Some(record("fresh-g"))),
            (
                "app|lib/restored.dart".to_owned(),
                Some(record("intermediate")),
            ),
        ]));
        // The transaction rewrote a.dart after the walk fingerprinted
        // it and restored restored.dart to its previous bytes: neither
        // report is evidence for the committed bytes, and the
        // previous-vs-final comparison cannot tell for restored.dart.
        // gone.dart is absent from the final snapshot.
        state.supersede_api_fingerprint_reports(&BTreeSet::from([
            "app|lib/a.dart".to_owned(),
            "app|lib/restored.dart".to_owned(),
        ]));
        state.update_assets(BTreeMap::from([
            ("app|lib/a.dart".to_owned(), entry("changed")),
            ("app|lib/restored.dart".to_owned(), entry("rrr")),
        ]));
        assert!(state.asset_fingerprints.is_empty());
    }

    #[test]
    fn update_assets_keeps_fingerprints_reported_by_the_current_build() {
        let entry = |digest: &str| crate::snapshot::AssetSnapshot {
            exists: true,
            digest: digest.to_owned(),
            size: 1,
        };
        let record = |fingerprint: &str| crate::protocol::ApiFingerprintRecord {
            digest: format!("d-{fingerprint}"),
            fingerprint: fingerprint.to_owned(),
        };
        let mut state = GraphState {
            assets: BTreeMap::from([("app|lib/a.dart".to_owned(), entry("aaa"))]),
            asset_fingerprints: BTreeMap::from([("app|lib/a.dart".to_owned(), record("stale"))]),
            ..GraphState::default()
        };
        // The build relearns the edited asset and a brand-new one;
        // both reports are fresh evidence for the new snapshot.
        state.merge_api_fingerprints(BTreeMap::from([
            ("app|lib/a.dart".to_owned(), Some(record("fresh"))),
            ("app|lib/new.dart".to_owned(), Some(record("new"))),
        ]));
        state.update_assets(BTreeMap::from([
            ("app|lib/a.dart".to_owned(), entry("changed")),
            ("app|lib/new.dart".to_owned(), entry("nnn")),
        ]));
        assert_eq!(
            state.asset_fingerprints,
            BTreeMap::from([
                ("app|lib/a.dart".to_owned(), record("fresh")),
                ("app|lib/new.dart".to_owned(), record("new")),
            ])
        );
    }

    #[test]
    fn old_binary_format_and_schema_are_discarded_without_removing_files() {
        let root =
            std::env::temp_dir().join(format!("accelerator-old-graph-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("graph.bin");
        let source = root.join("source.dart");
        let output = root.join("source.g.dart");
        std::fs::write(&source, b"user source").unwrap();
        std::fs::write(&output, b"existing output").unwrap();
        for (format, schema) in [
            (1, super::GRAPH_SCHEMA_VERSION),
            (2, super::GRAPH_SCHEMA_VERSION),
            (99, super::GRAPH_SCHEMA_VERSION),
            (super::GRAPH_FORMAT_VERSION, 1),
            (super::GRAPH_FORMAT_VERSION, 7),
            (super::GRAPH_FORMAT_VERSION, 8),
        ] {
            let previous = GraphState {
                schema_version: schema,
                config_digest: "obsolete configuration".to_owned(),
                ..GraphState::default()
            };
            let mut encoder = super::Encoder::new();
            encoder.write_graph_state(&previous).unwrap();
            let mut payload = encoder.finish();
            match format {
                // Empty format-1 metadata ends after resolver edges.
                1 => payload.truncate(payload.len() - 17),
                2 => {
                    payload.pop();
                }
                _ => {}
            }
            let mut bytes = super::GRAPH_MAGIC.to_vec();
            bytes.push(format);
            bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
            bytes.extend_from_slice(&payload);
            std::fs::write(&path, &bytes).unwrap();
            let state = GraphState::load(&path).unwrap();
            assert!(state.actions.is_empty());
            assert!(state.config_digest.is_empty());
            assert_eq!(state.schema_version, super::GRAPH_SCHEMA_VERSION);
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            assert_eq!(std::fs::read(&source).unwrap(), b"user source");
            assert_eq!(std::fs::read(&output).unwrap(), b"existing output");
        }
        assert!(
            GraphState::load(&root).is_err(),
            "filesystem IO errors stay explicit"
        );
        std::fs::remove_dir_all(root).unwrap();
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

        let error = GraphState::load_checked(&path).expect_err("invalid graph should fail");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        let recovered = GraphState::load(&path).expect("regenerate invalid graph");
        assert!(recovered.actions.is_empty());
        assert!(path.exists());

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
