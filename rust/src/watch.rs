mod graph;

use self::graph::ResidentGraph;
use crate::build;
use crate::builder::{ConfiguredBuilder, RustBuildConfig};
use crate::cli::Options;
use crate::frontend::{NativeFrontend, prepare_native_frontend, unsupported, worker_executable};
use crate::graph::GraphState;
use crate::pattern::match_capture_pattern;
use crate::worker::WorkerPool;
use crate::workspace::Workspace;
use notify::{
    Event, EventKind, RecursiveMode, Watcher,
    event::{ModifyKind, RenameMode},
};
use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

#[derive(Default)]
pub(crate) struct WatchChanges {
    pub(crate) paths: BTreeSet<PathBuf>,
    pub(crate) added_paths: BTreeSet<PathBuf>,
}

#[derive(Default)]
struct WatchEvents {
    watcher: Option<notify::RecommendedWatcher>,
    receiver: Option<Receiver<notify::Result<Event>>>,
}

impl WatchEvents {
    // Subscribe once after native-plan validation. The channel is left unread
    // until the initial build completes so in-build edits queue for the loop.
    fn start(&mut self, workspace: &Workspace) -> io::Result<()> {
        if self.watcher.is_some() {
            return Ok(());
        }

        let (sender, receiver) = mpsc::channel();
        let mut watcher = notify::recommended_watcher(move |result| {
            let _ = sender.send(result);
        })
        .map_err(io::Error::other)?;
        for package_root in workspace.package_roots() {
            if package_root != workspace.root && package_root.starts_with(&workspace.root) {
                continue;
            }
            watcher
                .watch(&package_root, RecursiveMode::Recursive)
                .map_err(io::Error::other)?;
        }
        self.watcher = Some(watcher);
        self.receiver = Some(receiver);
        Ok(())
    }
}

#[derive(Default)]
struct WatchState {
    cached_configuration: Option<RustBuildConfig>,
    events: WatchEvents,
    graph: ResidentGraph,
}

fn added_event_paths(event: &Event) -> Vec<PathBuf> {
    match event.kind {
        EventKind::Create(_) | EventKind::Modify(ModifyKind::Name(RenameMode::To)) => event
            .paths
            .iter()
            .map(|path| normalized_watch_path(path))
            .collect(),
        EventKind::Modify(ModifyKind::Name(RenameMode::Both)) => event
            .paths
            .last()
            .map(|path| vec![normalized_watch_path(path)])
            .unwrap_or_default(),
        EventKind::Modify(ModifyKind::Name(RenameMode::Any)) => event
            .paths
            .iter()
            .filter(|path| path.is_file())
            .map(|path| normalized_watch_path(path))
            .collect(),
        _ => Vec::new(),
    }
}

pub(crate) fn run(options: &Options) -> io::Result<()> {
    let mut pool = None;
    let mut pool_signature = None;
    let mut pool_shape = None;
    let mut watch_state = WatchState::default();
    let settings = &options.settings;
    let stock_config_path = settings
        .config
        .as_ref()
        .map(|key| format!("build.{key}.yaml"));
    // Stock reads normalized AssetIds, but its watch reload predicate compares
    // the unnormalized spelling. Such a file edit is an ordinary source event;
    // keep the resolved plan until a recognized configuration change occurs.
    let normalized_config_path = settings.config_path()?;
    let mut retain_configuration = stock_config_path
        .as_ref()
        .is_some_and(|raw| normalized_config_path.as_ref() != Some(raw));
    let mut source_post_process_outputs = BTreeSet::new();

    let mut native_build_succeeded = match run_watch_build(
        options,
        &mut pool,
        &mut pool_signature,
        &mut pool_shape,
        &mut watch_state,
        false,
        &WatchChanges::default(),
    ) {
        Ok(()) => true,
        Err(error) if crate::frontend::is_terminal_frontend_error(&error) => return Err(error),
        Err(error) => {
            eprintln!("initial watch build failed: {error}");
            false
        }
    };

    let workspace = Workspace::load(options.root.clone())?;
    // Preserve watch recovery when the first native attempt fails before plan
    // selection reaches the early subscription point.
    watch_state.events.start(&workspace)?;
    if let Some(path) = &normalized_config_path {
        let file = workspace.root.join(path);
        // Stock attributes an event to the deepest package. A selected root
        // AssetId physically inside a dependency is not a root config event.
        retain_configuration |= configuration_package_root(&workspace, &file)
            .is_some_and(|root| root != workspace.root);
    }
    if native_build_succeeded {
        source_post_process_outputs =
            load_source_post_process_outputs(&workspace.root, watch_state.graph.committed());
    }
    println!(
        "Watching {} (native filesystem events)",
        workspace.root.display()
    );

    loop {
        if let Some(config) = &watch_state.cached_configuration {
            workspace.configure_sources(config.asset_sources.as_ref());
        }
        // This flag records whether any build has succeeded. Later builder
        // failures retain event classification from the committed disk graph.
        let previous_state = if native_build_succeeded {
            Some(
                watch_state
                    .graph
                    .for_events(&build::graph_path(&workspace))?,
            )
        } else {
            // Even an initial publication failure must roll back before waiting
            // or classifying events against a partially changed output tree.
            crate::build::recovery::recover(&build::graph_path(&workspace))?;
            None
        };
        let (configuration_changed, changed_paths) = wait_for_relevant_event(
            watch_state
                .events
                .receiver
                .as_ref()
                .ok_or_else(|| io::Error::other("native watch was not initialized"))?,
            &workspace,
            &source_post_process_outputs,
            options.interval_ms,
            stock_config_path.as_deref(),
            previous_state,
            !settings.build_filters.is_empty(),
        )?;

        eprintln!("Change detected; rebuilding");
        match run_watch_build(
            options,
            &mut pool,
            &mut pool_signature,
            &mut pool_shape,
            &mut watch_state,
            retain_configuration && !configuration_changed,
            &changed_paths,
        ) {
            Ok(()) => {
                native_build_succeeded = true;
                source_post_process_outputs = load_source_post_process_outputs(
                    &workspace.root,
                    watch_state.graph.committed(),
                );
            }
            Err(error) if crate::frontend::is_terminal_frontend_error(&error) => return Err(error),
            Err(error) => {
                eprintln!("watch build failed: {error}");
            }
        }
    }
}

/// These reloads happen outside build metrics, including the graph held while
/// waiting for source events. Keep their cost visible before changing ownership.
fn load_watch_graph(path: &Path, purpose: &str) -> io::Result<GraphState> {
    let started = crate::metrics::runtime_metrics_enabled().then(Instant::now);
    let result = GraphState::load(path);
    if let Some(started) = started {
        eprintln!(
            "Rust watch graph metrics: purpose={} load_us={} load_bytes={} success={}",
            purpose,
            started.elapsed().as_micros(),
            crate::metrics::graph_file_size(path),
            result.is_ok(),
        );
    }
    result
}

/// Includes workspace/configuration preparation and worker setup, even when
/// they fail before the build can emit its ordinary graph/execution metrics.
struct WatchCycleMetrics {
    started: Option<Instant>,
    success: bool,
}

impl Drop for WatchCycleMetrics {
    fn drop(&mut self) {
        if let Some(started) = self.started {
            eprintln!(
                "Rust watch cycle metrics: elapsed_us={} success={}",
                started.elapsed().as_micros(),
                self.success
            );
        }
    }
}

fn run_watch_build(
    options: &Options,
    pool: &mut Option<WorkerPool>,
    pool_signature: &mut Option<String>,
    pool_shape: &mut Option<Vec<ConfiguredBuilder>>,
    watch_state: &mut WatchState,
    reuse_configuration: bool,
    changed_paths: &WatchChanges,
) -> io::Result<()> {
    let mut cycle_metrics = WatchCycleMetrics {
        started: crate::metrics::runtime_metrics_enabled().then(Instant::now),
        success: false,
    };
    let _wall = crate::wall::Session::new();
    let workspace = Workspace::load(options.root.clone())?;
    let loaded_graph = watch_state.graph.take_for_build(&workspace)?;
    let session_start = watch_state.cached_configuration.is_none();
    let filtered = !options.settings.build_filters.is_empty();
    let mut frontend = if reuse_configuration {
        if let Some(config) = &watch_state.cached_configuration {
            NativeFrontend::new(config.clone())
        } else {
            prepare_native_frontend(options, &workspace, &loaded_graph.state)?
        }
    } else {
        prepare_native_frontend(options, &workspace, &loaded_graph.state)?
    };
    let build_config = &frontend.config;
    workspace.configure_sources(build_config.asset_sources.as_ref());
    if let Some(reason) = workspace.overlapping_watch_sources()? {
        pool.take();
        return unsupported(&reason);
    }
    // A successful cold build can discover resolver cycles. Re-check the
    // incremental evidence even when filesystem events reuse the manifest.
    let transition_reason = if !reuse_configuration {
        None
    } else if filtered {
        build::filtered_transition_reason(
            &workspace,
            build_config,
            false,
            &loaded_graph.state,
            &mut frontend.preflight,
        )?
    } else {
        build::dependency_output_conflict_reason(
            &workspace,
            build_config,
            &loaded_graph.state,
            &mut frontend.preflight,
        )?
    };
    if let Some(reason) = transition_reason {
        pool.take();
        return unsupported(reason);
    }

    // Stock 2.16.2 reloads the plan in watch, but changing application/output
    // topology does not behave like a fresh build. Do not partially emulate
    // that transition: reject the transition before publishing outputs.
    let shape: Vec<_> = build_config
        .builders
        .iter()
        .cloned()
        .map(|mut builder| {
            builder.options.clear();
            // Trigger updates retain the existing native watch contract.
            std::sync::Arc::make_mut(&mut builder.definition)
                .triggers
                .clear();
            builder
        })
        .collect();
    if pool_shape
        .as_ref()
        .is_some_and(|previous| previous != &shape)
        || watch_state
            .cached_configuration
            .as_ref()
            .is_some_and(|previous| previous.asset_sources != build_config.asset_sources)
    {
        pool.take();
        let reason = "watch configuration changed builder applications or output topology";
        return unsupported(reason);
    }
    *pool_shape = Some(shape);
    watch_state.cached_configuration = Some(build_config.clone());
    if *pool_signature != build_config.manifest_signature {
        pool.take();
        *pool_signature = build_config.manifest_signature.clone();
    }
    // Subscribe only after the native plan is known to be supported, and before
    // worker startup or the initial build can observe source files. Events are
    // consumed by run() after the initial build so edits made during it remain
    // queued for the next watch cycle.
    watch_state.events.start(&workspace)?;
    if pool.is_none() {
        let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
        let worker_command = worker_executable(options, build_config)?;
        let mut worker_pool = if filtered {
            WorkerPool::start_deferred(
                &workspace,
                dart_binary,
                &worker_command,
                options.jobs,
                options.worker.is_none(),
            )?
        } else {
            WorkerPool::start(
                &workspace,
                dart_binary,
                &worker_command,
                options.jobs,
                options.worker.is_none(),
            )?
        };
        worker_pool.pin_worker_artifact();
        *pool = Some(worker_pool);
    }
    let state_path = build::graph_path(&workspace);
    let committed = build::run_with_config_session(
        options,
        pool.as_mut(),
        workspace,
        frontend,
        loaded_graph,
        session_start,
        changed_paths,
    )?;
    // The owned working graph is returned only after successful publication.
    // Any earlier error drops it; the next attempt then reloads disk state.
    watch_state.graph.publish(&state_path, committed);
    cycle_metrics.success = true;
    Ok(())
}

fn wait_for_relevant_event(
    receiver: &Receiver<notify::Result<Event>>,
    workspace: &Workspace,
    source_post_process_outputs: &BTreeSet<String>,
    debounce_ms: u64,
    stock_config_path: Option<&str>,
    previous_state: Option<&GraphState>,
    filtered: bool,
) -> io::Result<(bool, WatchChanges)> {
    loop {
        let event = receiver.recv().map_err(io::Error::other)?;
        let event = event.map_err(io::Error::other)?;
        if !is_relevant_event(
            workspace,
            &event,
            source_post_process_outputs,
            stock_config_path,
            previous_state,
            filtered,
        ) {
            continue;
        }

        let mut configuration_changed =
            is_configuration_event(workspace, &event, stock_config_path);
        let mut changed_paths: BTreeSet<_> = event
            .paths
            .iter()
            .map(|path| normalized_watch_path(path))
            .collect();
        let mut added_paths: BTreeSet<_> = added_event_paths(&event).into_iter().collect();
        // Coalesce the burst from one save/atomic rename into one build.
        // Only relevant events extend the quiet window, and an absolute
        // deadline caps the total wait, so sustained unrelated writes (for
        // example a background AOT compile under .dart_tool) cannot starve
        // the rebuild.
        let debounce = Duration::from_millis(debounce_ms);
        let deadline = Instant::now() + debounce.saturating_mul(8).max(Duration::from_secs(2));
        let mut quiet_until = Instant::now() + debounce;
        loop {
            let now = Instant::now();
            let remaining = deadline
                .saturating_duration_since(now)
                .min(quiet_until.saturating_duration_since(now));
            if remaining.is_zero() {
                break;
            }
            match receiver.recv_timeout(remaining) {
                Ok(Ok(event)) => {
                    if is_relevant_event(
                        workspace,
                        &event,
                        source_post_process_outputs,
                        stock_config_path,
                        previous_state,
                        filtered,
                    ) {
                        configuration_changed |=
                            is_configuration_event(workspace, &event, stock_config_path);
                        changed_paths
                            .extend(event.paths.iter().map(|path| normalized_watch_path(path)));
                        added_paths.extend(added_event_paths(&event));
                        quiet_until = Instant::now() + debounce;
                    }
                }
                Ok(Err(_)) => {}
                Err(_) => break,
            }
        }
        return Ok((
            configuration_changed,
            WatchChanges {
                paths: changed_paths,
                added_paths,
            },
        ));
    }
}

// Package-config relative URIs are stored as joined paths by Workspace. Stock
// resolves URI dot segments before assigning an event to the deepest package.
pub(crate) fn normalized_watch_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            _ => normalized.push(component.as_os_str()),
        }
    }
    normalized
}

fn configuration_package_root(workspace: &Workspace, path: &Path) -> Option<PathBuf> {
    let path = normalized_watch_path(path);
    workspace
        .package_roots()
        .into_iter()
        .map(|root| normalized_watch_path(&root))
        .filter(|root| path.starts_with(root))
        .max_by_key(|root| root.components().count())
}

fn is_configuration_event(workspace: &Workspace, event: &Event, selected: Option<&str>) -> bool {
    event.paths.iter().any(|path| {
        let path = normalized_watch_path(path);
        let root = configuration_package_root(workspace, &path);
        let Some(root) = root else { return false };
        let Ok(relative) = path.strip_prefix(&root) else {
            return false;
        };
        let relative = relative.to_string_lossy().replace('\\', "/");
        relative == "build.yaml"
            || relative.ends_with(".build.yaml")
            || (root == workspace.root && selected == Some(relative.as_str()))
    })
}

fn load_source_post_process_outputs(
    root: &Path,
    committed: Option<&GraphState>,
) -> BTreeSet<String> {
    let manifest_path = root.join(".dart_tool/build_runner_accelerator/builder-manifest.json");
    let Ok(contents) = fs::read_to_string(manifest_path) else {
        return BTreeSet::new();
    };
    let Ok(manifest) = serde_json::from_str::<serde_json::Value>(&contents) else {
        return BTreeSet::new();
    };
    let Some(builders) = manifest.get("builders").and_then(|value| value.as_array()) else {
        return BTreeSet::new();
    };
    let source_post_process_ids = builders
        .iter()
        .filter(|builder| {
            builder.get("kind").and_then(|value| value.as_str()) == Some("post_process")
                && builder.get("build_to").and_then(|value| value.as_str()) == Some("source")
        })
        .filter_map(|builder| builder.get("id").and_then(|value| value.as_str()))
        .collect::<BTreeSet<_>>();
    if source_post_process_ids.is_empty() {
        return BTreeSet::new();
    }

    let graph_path = root.join(".dart_tool/build_runner_accelerator/graph-v3.bin");
    let loaded;
    let state = match committed {
        Some(state) => state,
        None => {
            loaded = match load_watch_graph(&graph_path, "post_process_outputs") {
                Ok(state) => state,
                Err(_) => return BTreeSet::new(),
            };
            &loaded
        }
    };
    state
        .actions
        .values()
        .filter(|action| source_post_process_ids.contains(action.builder.as_str()))
        .flat_map(|action| action.outputs.iter())
        .filter_map(|output| output.split_once('|').map(|_| output.clone()))
        .collect()
}

fn is_generated_output(
    root: &Path,
    path: &Path,
    root_package: &str,
    source_post_process_outputs: &BTreeSet<String>,
) -> bool {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    let Some(relative) = path.strip_prefix(root).ok().and_then(Path::to_str) else {
        return false;
    };
    let manifest_path = root.join(".dart_tool/build_runner_accelerator/builder-manifest.json");
    let Ok(contents) = fs::read_to_string(manifest_path) else {
        return false;
    };
    let Ok(manifest) = serde_json::from_str::<serde_json::Value>(&contents) else {
        return false;
    };
    let Some(builders) = manifest.get("builders").and_then(|value| value.as_array()) else {
        return false;
    };
    if builders.iter().any(|builder| {
        builder.get("build_to").and_then(|value| value.as_str()) == Some("source")
            && builder
                .get("extensions")
                .and_then(|value| value.as_array())
                .is_some_and(|extensions| {
                    extensions.iter().any(|extension| {
                        extension
                            .get("output_suffixes")
                            .and_then(|value| value.as_array())
                            .is_some_and(|suffixes| {
                                suffixes
                                    .iter()
                                    .filter_map(|suffix| suffix.as_str())
                                    .any(|suffix| output_pattern_matches(relative, name, suffix))
                            })
                    })
                })
    }) {
        return true;
    }

    let asset = format!("{root_package}|{}", relative.replace('\\', "/"));
    source_post_process_outputs.contains(&asset)
}

fn output_pattern_matches(relative: &str, name: &str, pattern: &str) -> bool {
    if pattern.contains("{{") {
        return match_capture_pattern(relative, pattern, false).is_some();
    }
    relative == pattern || relative.ends_with(pattern) || name.ends_with(pattern)
}

fn is_relevant_event(
    workspace: &Workspace,
    event: &Event,
    source_post_process_outputs: &BTreeSet<String>,
    selected: Option<&str>,
    previous_state: Option<&GraphState>,
    filtered: bool,
) -> bool {
    if !matches!(
        event.kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
    ) {
        return false;
    }
    event.paths.iter().any(|path| {
        let path = normalized_watch_path(path);
        if path.is_dir() {
            return false;
        }
        let package = workspace
            .packages()
            .map(|(package, root)| (package, normalized_watch_path(root)))
            .filter(|(_, root)| path.starts_with(root))
            .max_by_key(|(_, root)| root.components().count());
        let Some((package, package_root)) = package else {
            return false;
        };
        let is_root_package = package == workspace.root_package;
        let relative = path
            .strip_prefix(&package_root)
            .ok()
            .and_then(Path::to_str)
            .unwrap_or_default()
            .replace('\\', "/");
        // An explicitly selected config takes precedence over generic native
        // artifact/generated-output filters, like stock's config predicate.
        if is_root_package && selected == Some(relative.as_str()) {
            return true;
        }
        let components = Path::new(&relative).components().collect::<Vec<_>>();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            return false;
        };
        if components
            .first()
            .is_some_and(|component| component.as_os_str().to_str() == Some(".dart_tool"))
        {
            return is_root_package && name == "package_config.json";
        }
        if relative == "build.yaml" || relative.ends_with(".build.yaml") {
            return true;
        }
        let asset = format!("{package}|{relative}");
        if !workspace.is_source_path(package, &relative)
            && !previous_state.is_some_and(|state| {
                state.assets.contains_key(&asset) || state.output_locations.contains_key(&asset)
            })
        {
            return false;
        }
        if is_root_package
            && is_generated_output(
                &workspace.root,
                &path,
                &workspace.root_package,
                source_post_process_outputs,
            )
        {
            if filtered && let Some(state) = previous_state {
                // Filtered state omits undemanded outputs. Their external
                // writes must reach conflict classification, even when the
                // filename also matches a generated-output suffix. Only
                // suppress source writes whose bytes match a committed result.
                if state.output_locations.get(&asset) == Some(&false)
                    && let Some(expected) = state
                        .actions
                        .values()
                        .find_map(|action| action.output_digests.get(&asset))
                    && let Ok(bytes) = fs::read(path)
                    && crate::digest::digest_bytes(&bytes) == *expected
                {
                    return false;
                }
                return true;
            }
            // Ignore our own generated writes, but rebuild if a generated
            // source file was removed by the user.
            return matches!(event.kind, EventKind::Remove(_));
        }
        !name.contains(".build-runner-accelerator-")
    })
}

#[cfg(test)]
mod manifest_tests {
    use super::*;

    #[test]
    fn rename_event_paths_preserve_modes_and_filter_any_to_existing_files() {
        let root = std::env::temp_dir().join(format!(
            "accelerator-watch-rename-paths-{}",
            std::process::id()
        ));
        let directory = root.join("lib");
        fs::create_dir_all(&directory).unwrap();
        let old = directory.join("old.side");
        let new = directory.join("new.side");
        fs::write(&old, "old").unwrap();
        fs::write(&new, "new").unwrap();
        let missing = directory.join("missing.side");
        let normalized_new = directory.join("new.side");

        let any_event = Event::new(EventKind::Modify(ModifyKind::Name(RenameMode::Any)))
            .add_path(directory.join(".").join("new.side"))
            .add_path(directory.clone())
            .add_path(missing.clone());
        assert_eq!(added_event_paths(&any_event), vec![normalized_new.clone()]);
        assert!(
            added_event_paths(
                &Event::new(EventKind::Modify(ModifyKind::Name(RenameMode::From)))
                    .add_path(old.clone())
            )
            .is_empty()
        );
        assert_eq!(
            added_event_paths(
                &Event::new(EventKind::Modify(ModifyKind::Name(RenameMode::To)))
                    .add_path(old.clone())
                    .add_path(new.clone())
            ),
            vec![old.clone(), new.clone()]
        );
        assert_eq!(
            added_event_paths(
                &Event::new(EventKind::Modify(ModifyKind::Name(RenameMode::Both)))
                    .add_path(old)
                    .add_path(new.clone())
            ),
            vec![normalized_new]
        );
        assert_eq!(
            added_event_paths(
                &Event::new(EventKind::Create(notify::event::CreateKind::File))
                    .add_path(new.clone())
            ),
            vec![new.clone()]
        );
        assert!(
            added_event_paths(
                &Event::new(EventKind::Remove(notify::event::RemoveKind::File)).add_path(new)
            )
            .is_empty()
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn events_follow_deepest_package_sources_and_preserve_tracked_assets() {
        let root = std::env::temp_dir().join(format!(
            "accelerator-watch-source-events-{}",
            std::process::id()
        ));
        fs::create_dir_all(root.join(".dart_tool")).unwrap();
        fs::write(root.join("pubspec.yaml"), "name: app\n").unwrap();
        fs::write(
            root.join(".dart_tool/package_config.json"),
            r#"{"configVersion":2,"packages":[{"name":"dep","rootUri":"../dep/"}]}"#,
        )
        .unwrap();
        let workspace = Workspace::load(root.clone()).unwrap();
        let sources = std::sync::Arc::new(serde_json::from_value(serde_json::json!({
            "app": {"targets": [{"include": ["lib/*.txt"], "exclude": []}], "public_assets": null},
            "dep": {"targets": [{"include": ["lib/**"], "exclude": []}], "public_assets": ["lib/**"]},
        })).unwrap());
        workspace.configure_sources(Some(&sources));
        let mut state = GraphState::default();
        state.assets.insert(
            "app|generated/out.final".into(),
            crate::snapshot::AssetSnapshot {
                exists: true,
                digest: crate::digest::digest_bytes(b"generated"),
                size: 9,
            },
        );
        state
            .output_locations
            .insert("app|generated/location-only.final".into(), false);
        for kind in [
            EventKind::Create(notify::event::CreateKind::File),
            EventKind::Modify(ModifyKind::Any),
            EventKind::Remove(notify::event::RemoveKind::File),
        ] {
            for (relative, relevant) in [
                (".git/unrelated.txt", false),
                ("build/unrelated.txt", false),
                ("target/unrelated.txt", false),
                ("dep/private/unrelated.txt", false),
                ("lib/input.txt", true),
                ("dep/lib/build/.input.txt", true),
                ("build.yaml", true),
                ("dep/build.yaml", true),
                ("overrides.build.yaml", true),
                ("selected/config.yaml", true),
                (".dart_tool/package_config.json", true),
                (
                    ".dart_tool/build_runner_accelerator/cache/out.build.yaml",
                    false,
                ),
                ("generated/out.final", true),
                ("generated/location-only.final", true),
                ("generated/untracked.final", false),
            ] {
                let event = Event::new(kind).add_path(root.join(relative));
                assert_eq!(
                    is_relevant_event(
                        &workspace,
                        &event,
                        &BTreeSet::new(),
                        Some("selected/config.yaml"),
                        Some(&state),
                        false
                    ),
                    relevant,
                    "{kind:?} {relative}"
                );
            }
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn filtered_generated_events_suppress_committed_bytes_but_accept_conflicts() {
        let root = std::env::temp_dir().join(format!(
            "accelerator-filtered-watch-events-{}",
            std::process::id()
        ));
        let directory = root.join(".dart_tool/build_runner_accelerator");
        fs::create_dir_all(&directory).unwrap();
        fs::create_dir_all(root.join("lib")).unwrap();
        fs::write(root.join("pubspec.yaml"), "name: app\n").unwrap();
        fs::write(
            root.join(".dart_tool/package_config.json"),
            r#"{"configVersion":2,"packages":[{"name":"app","rootUri":"../"}]}"#,
        )
        .unwrap();
        fs::write(
            directory.join("builder-manifest.json"),
            r#"{"builders":[{"build_to":"source","extensions":[{"output_suffixes":[".final"]}]}]}"#,
        )
        .unwrap();
        let output = root.join("lib/a.final");
        fs::write(&output, "generated").unwrap();
        let workspace = Workspace::load(root.clone()).unwrap();
        let event = Event::new(EventKind::Modify(ModifyKind::Any)).add_path(output.clone());
        let mut state = GraphState::default();
        state
            .output_locations
            .insert("app|lib/a.final".into(), false);
        state.actions.insert(
            "producer".into(),
            crate::graph::ActionState {
                outputs: vec!["app|lib/a.final".into()],
                output_digests: [(
                    "app|lib/a.final".into(),
                    crate::digest::digest_bytes(b"generated"),
                )]
                .into(),
                ..Default::default()
            },
        );
        assert!(!is_relevant_event(
            &workspace,
            &event,
            &BTreeSet::new(),
            None,
            Some(&state),
            true
        ));
        fs::write(&output, "external edit").unwrap();
        assert!(is_relevant_event(
            &workspace,
            &event,
            &BTreeSet::new(),
            None,
            Some(&state),
            true
        ));
        // An undemanded output has no committed digest, even when an external
        // write leaves the same bytes on disk. It must reach conflict cleanup.
        state.actions.clear();
        state.output_locations.clear();
        assert!(is_relevant_event(
            &workspace,
            &event,
            &BTreeSet::new(),
            None,
            Some(&state),
            true
        ));
        // Ordinary watch retains its existing event contract.
        assert!(!is_relevant_event(
            &workspace,
            &event,
            &BTreeSet::new(),
            None,
            None,
            false
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn selected_config_uses_deepest_package_with_parent_and_child_dependencies() {
        let parent =
            std::env::temp_dir().join(format!("accelerator-watch-packages-{}", std::process::id()));
        let root = parent.join("example");
        fs::create_dir_all(root.join(".dart_tool")).unwrap();
        fs::write(root.join("pubspec.yaml"), "name: example\n").unwrap();
        fs::write(
            root.join(".dart_tool/package_config.json"),
            r#"{"configVersion":2,"packages":[{"name":"parent","rootUri":"../../"},{"name":"child","rootUri":"../build.dir/"}]}"#,
        )
        .unwrap();
        let workspace = Workspace::load(root).unwrap();
        let root_config = workspace.root.join("build.named.yaml");
        assert_eq!(
            configuration_package_root(&workspace, &root_config),
            Some(workspace.root.clone())
        );
        let root_event =
            Event::new(EventKind::Modify(notify::event::ModifyKind::Any)).add_path(root_config);
        assert!(is_configuration_event(
            &workspace,
            &root_event,
            Some("build.named.yaml")
        ));
        let child_config = workspace.root.join("build.dir/name.yaml");
        assert_eq!(
            configuration_package_root(&workspace, &child_config),
            Some(workspace.root.join("build.dir"))
        );
        let child_event =
            Event::new(EventKind::Modify(notify::event::ModifyKind::Any)).add_path(child_config);
        assert!(!is_configuration_event(
            &workspace,
            &child_event,
            Some("build.dir/name.yaml")
        ));
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn watch_reads_explicit_extensions_without_flattened_fields() {
        let root =
            std::env::temp_dir().join(format!("accelerator-watch-manifest-{}", std::process::id()));
        let state = root.join(".dart_tool/build_runner_accelerator");
        fs::create_dir_all(&state).unwrap();
        let path = root.join("lib/model.g.dart");
        let manifest_path = state.join("builder-manifest.json");
        fs::write(&manifest_path, r#"{"version":9,"builders":[{"build_to":"source","extensions":[{"input_suffix":".dart","output_suffixes":[".g.dart"]}]}]}"#).unwrap();
        assert!(is_generated_output(&root, &path, "app", &BTreeSet::new()));
        fs::write(&manifest_path, r#"{"version":8,"builders":[{"build_to":"source","output_suffix":".g.dart","output_suffixes":[".g.dart"]}]}"#).unwrap();
        assert!(!is_generated_output(&root, &path, "app", &BTreeSet::new()));
        fs::remove_dir_all(root).unwrap();
    }
}
