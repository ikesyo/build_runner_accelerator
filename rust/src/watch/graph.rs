//! Successful watch state is resident only between attempts. Execution takes
//! ownership; an error drops its tentative mutations and retries from disk.
use crate::build::LoadedGraph;
use crate::graph::GraphState;
use crate::workspace::Workspace;
use std::fs;
use std::io;
use std::path::Path;
use std::time::SystemTime;

#[derive(Debug, PartialEq, Eq)]
struct Stamp {
    length: u64,
    modified: SystemTime,
    #[cfg(unix)]
    identity: (u64, u64, i64, i64),
}

impl Stamp {
    fn read(path: &Path) -> io::Result<Option<Self>> {
        let metadata = match fs::metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let Ok(modified) = metadata.modified() else {
            return Ok(None);
        };
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Ok(Some(Self {
            length: metadata.len(),
            modified,
            #[cfg(unix)]
            identity: (
                metadata.dev(),
                metadata.ino(),
                metadata.ctime(),
                metadata.ctime_nsec(),
            ),
        }))
    }
}

struct Committed {
    state: GraphState,
    stamp: Option<Stamp>,
}

#[derive(Default)]
pub(super) struct ResidentGraph(Option<Committed>);

impl ResidentGraph {
    pub fn committed(&self) -> Option<&GraphState> {
        self.0.as_ref().map(|entry| &entry.state)
    }

    pub fn publish(&mut self, path: &Path, state: Option<GraphState>) {
        self.0 = state.map(|state| Committed {
            state,
            stamp: Stamp::read(path).ok().flatten(),
        });
    }

    fn recover(&mut self, path: &Path) -> io::Result<()> {
        match crate::build::recovery::recover(path) {
            Ok(false) => Ok(()),
            Ok(true) => {
                self.0 = None;
                Ok(())
            }
            Err(error) => {
                self.0 = None;
                Err(error)
            }
        }
    }

    pub fn for_events(&mut self, path: &Path) -> io::Result<&GraphState> {
        self.recover(path)?;
        let stamp = Stamp::read(path)?;
        if !self
            .0
            .as_ref()
            .is_some_and(|entry| stamp.is_some() && entry.stamp == stamp)
        {
            // Do not preserve stale state across an unsuccessful reload.
            self.0 = None;
            let state = super::load_watch_graph(path, "event_filter")?;
            self.publish(path, Some(state));
        }
        Ok(&self.0.as_ref().unwrap().state)
    }

    pub fn take_for_build(&mut self, workspace: &Workspace) -> io::Result<LoadedGraph> {
        let path = crate::build::graph_path(workspace);
        self.recover(&path)?;
        if let Some(entry) = self.0.take() {
            let stamp = Stamp::read(&path)?;
            if stamp.is_some() && entry.stamp == stamp {
                if crate::metrics::runtime_metrics_enabled() {
                    eprintln!(
                        "Rust watch graph metrics: purpose=build source=resident load_us=0 load_bytes={}",
                        stamp.as_ref().map_or(0, |stamp| stamp.length)
                    );
                }
                return Ok(LoadedGraph::resident(entry.state, &path));
            }
        }
        LoadedGraph::load(workspace)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::GRAPH_SCHEMA_VERSION;
    use std::path::PathBuf;
    use std::time::UNIX_EPOCH;

    struct Fixture {
        root: PathBuf,
        workspace: Workspace,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "resident-graph-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir_all(root.join(".dart_tool")).unwrap();
            fs::write(
                root.join("pubspec.yaml"),
                "name: app\nenvironment:\n  sdk: '>=3.11.0 <4.0.0'\n",
            )
            .unwrap();
            fs::write(root.join(".dart_tool/package_config.json"), r#"{"configVersion":2,"packages":[{"name":"app","rootUri":"../","packageUri":"lib/","languageVersion":"3.11"}]}"#).unwrap();
            let workspace = Workspace::load(root.clone()).unwrap();
            Self { root, workspace }
        }
        fn path(&self) -> PathBuf {
            crate::build::graph_path(&self.workspace)
        }
        fn state(&self, digest: &str) -> GraphState {
            let state = GraphState {
                schema_version: GRAPH_SCHEMA_VERSION,
                config_digest: digest.to_owned(),
                ..GraphState::default()
            };
            state.save(&self.path()).unwrap();
            state
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn moves_successful_state_without_cloning_and_reloads_after_failed_attempt() {
        let fixture = Fixture::new();
        let state = fixture.state("last-successful-publication");
        let allocation = state.config_digest.as_ptr();
        let mut resident = ResidentGraph::default();
        resident.publish(&fixture.path(), Some(state));
        assert_eq!(
            resident
                .for_events(&fixture.path())
                .unwrap()
                .config_digest
                .as_ptr(),
            allocation
        );
        let mut working = resident.take_for_build(&fixture.workspace).unwrap();
        assert!(resident.committed().is_none());
        assert_eq!(working.state.config_digest.as_ptr(), allocation);
        working.state.config_digest = "failed-tentative-mutation".to_owned();
        drop(working);
        assert_eq!(
            resident.for_events(&fixture.path()).unwrap().config_digest,
            "last-successful-publication"
        );
    }

    #[test]
    fn publication_error_and_plan_only_do_not_seed_resident_state() {
        let fixture = Fixture::new();
        fixture.state("disk-state");
        let mut resident = ResidentGraph::default();
        let mut working = resident.take_for_build(&fixture.workspace).unwrap();
        assert!(resident.committed().is_none());
        working.state.config_digest = "tentative".to_owned();
        fs::create_dir(fixture.path().with_extension("bin.tmp")).unwrap();
        assert!(working.state.save(&fixture.path()).is_err());
        drop(working);
        assert!(resident.committed().is_none());
        assert_eq!(
            resident
                .take_for_build(&fixture.workspace)
                .unwrap()
                .state
                .config_digest,
            "disk-state"
        );
        resident.publish(&fixture.path(), None);
        assert!(resident.committed().is_none());
    }

    #[test]
    fn revalidates_replacement_corruption_and_deletion_before_reuse() {
        let fixture = Fixture::new();
        let mut resident = ResidentGraph::default();
        resident.publish(&fixture.path(), Some(fixture.state("original")));
        fixture.state("replacement-with-different-size");
        assert_eq!(
            resident.for_events(&fixture.path()).unwrap().config_digest,
            "replacement-with-different-size"
        );
        // Check again after event waiting, before execution takes ownership.
        fs::write(fixture.path(), b"corrupt").unwrap();
        assert!(
            resident
                .take_for_build(&fixture.workspace)
                .unwrap()
                .state
                .config_digest
                .is_empty()
        );
        resident.publish(&fixture.path(), Some(fixture.state("old-state")));
        fs::remove_file(fixture.path()).unwrap();
        assert!(
            resident
                .for_events(&fixture.path())
                .unwrap()
                .config_digest
                .is_empty()
        );
        assert!(
            resident
                .take_for_build(&fixture.workspace)
                .unwrap()
                .state
                .config_digest
                .is_empty()
        );
    }

    #[test]
    fn failed_reload_clears_stale_resident_state() {
        let fixture = Fixture::new();
        let mut resident = ResidentGraph::default();
        resident.publish(&fixture.path(), Some(fixture.state("old-state")));
        fs::remove_file(fixture.path()).unwrap();
        fs::create_dir(fixture.path()).unwrap();
        assert!(resident.for_events(&fixture.path()).is_err());
        assert!(resident.committed().is_none());
    }
}
