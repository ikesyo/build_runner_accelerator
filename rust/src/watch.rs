use crate::build;
use crate::cli::Options;
use crate::frontend::{run_dart_fallback, select_frontend, worker_executable};
use crate::pattern::match_capture_pattern;
use crate::worker::WorkerPool;
use crate::workspace::Workspace;
use notify::{Event, EventKind, RecursiveMode, Watcher};
use std::fs;
use std::io;
use std::path::Path;
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

pub(crate) fn run(options: &Options) -> io::Result<()> {
    let mut pool = None;

    if let Err(error) = run_watch_build(options, &mut pool) {
        eprintln!("initial watch build failed: {error}");
    }

    let workspace = Workspace::load(options.root.clone())?;
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
    println!(
        "Watching {} (native filesystem events)",
        workspace.root.display()
    );

    loop {
        if !wait_for_relevant_event(&receiver, &workspace, options.interval_ms)? {
            continue;
        }

        eprintln!("Change detected; rebuilding");
        if let Err(error) = run_watch_build(options, &mut pool) {
            eprintln!("watch build failed: {error}");
        }
    }
}

fn run_watch_build(options: &Options, pool: &mut Option<WorkerPool>) -> io::Result<()> {
    let workspace = Workspace::load(options.root.clone())?;
    let Some(build_config) = select_frontend(options, &workspace)? else {
        pool.take();
        return run_dart_fallback(options, &workspace);
    };

    if pool.is_none() {
        let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
        let worker_command = worker_executable(options, &build_config)?;
        *pool = Some(WorkerPool::start(
            &workspace.root,
            dart_binary,
            &worker_command,
            options.jobs,
            options.worker.is_none(),
        )?);
    }
    build::run_with_config(options, pool.as_mut(), workspace, build_config)
}

fn wait_for_relevant_event(
    receiver: &Receiver<notify::Result<Event>>,
    workspace: &Workspace,
    debounce_ms: u64,
) -> io::Result<bool> {
    loop {
        let event = receiver.recv().map_err(io::Error::other)?;
        let event = event.map_err(io::Error::other)?;
        if !is_relevant_event(workspace, &event) {
            continue;
        }

        // Coalesce the burst from one save/atomic rename into one build.
        while receiver
            .recv_timeout(Duration::from_millis(debounce_ms))
            .is_ok()
        {}
        return Ok(true);
    }
}

fn is_generated_output(root: &Path, path: &Path) -> bool {
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
    manifest
        .get("builders")
        .and_then(|value| value.as_array())
        .is_some_and(|builders| {
            builders.iter().any(|builder| {
                builder.get("build_to").and_then(|value| value.as_str()) == Some("source")
                    && (builder
                        .get("output_suffixes")
                        .and_then(|value| value.as_array())
                        .is_some_and(|suffixes| {
                            suffixes
                                .iter()
                                .filter_map(|suffix| suffix.as_str())
                                .any(|suffix| output_pattern_matches(relative, name, suffix))
                        })
                        || builder
                            .get("output_suffix")
                            .and_then(|value| value.as_str())
                            .is_some_and(|suffix| output_pattern_matches(relative, name, suffix)))
            })
        })
}

fn output_pattern_matches(relative: &str, name: &str, pattern: &str) -> bool {
    if pattern.contains("{{") {
        return match_capture_pattern(relative, pattern, false).is_some();
    }
    relative == pattern || relative.ends_with(pattern) || name.ends_with(pattern)
}

fn is_relevant_event(workspace: &Workspace, event: &Event) -> bool {
    if !matches!(
        event.kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
    ) {
        return false;
    }
    event.paths.iter().any(|path| {
        if path.is_dir() {
            return false;
        }
        let package_root = workspace
            .package_roots()
            .into_iter()
            .filter(|root| path.starts_with(root))
            .max_by_key(|root| root.components().count());
        let Some(package_root) = package_root else {
            return false;
        };
        let is_root_package = package_root == workspace.root;
        let relative = path
            .strip_prefix(package_root)
            .ok()
            .and_then(Path::to_str)
            .unwrap_or_default();
        let components = Path::new(relative).components().collect::<Vec<_>>();
        if components.iter().any(|component| {
            matches!(
                component.as_os_str().to_str(),
                Some(".git" | "build" | "target")
            )
        }) {
            return false;
        }
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            return false;
        };
        if components.first().is_some_and(|component| {
            component.as_os_str().to_str() == Some(".dart_tool")
        }) {
            return is_root_package && name == "package_config.json";
        }
        if is_root_package && is_generated_output(&workspace.root, path) {
            // Ignore our own generated writes, but rebuild if a generated
            // source file was removed by the user.
            return matches!(event.kind, EventKind::Remove(_));
        }
        !name.contains(".build-runner-accelerator-")
    })
}
