use crate::build;
use crate::builder::{ConfiguredBuilder, RustBuildConfig};
use crate::cli::{BuildSettings, FrontendMode, Options};
use crate::frontend::{run_dart_fallback, select_frontend, worker_executable};
use crate::graph::GraphState;
use crate::pattern::match_capture_pattern;
use crate::worker::WorkerPool;
use crate::workspace::Workspace;
use notify::{Event, EventKind, RecursiveMode, Watcher};
use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

pub(crate) fn run(options: &Options) -> io::Result<()> {
    let mut pool = None;
    let mut pool_signature = None;
    let mut pool_shape = None;
    let mut cached_configuration = None;
    let settings = BuildSettings::parse(&options.stock_arguments)?;
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

    let initial_native_build = match run_watch_build(
        options,
        &mut pool,
        &mut pool_signature,
        &mut pool_shape,
        &mut cached_configuration,
        false,
    ) {
        Ok(native_build) => native_build,
        Err(error) if error.kind() == io::ErrorKind::Unsupported => return Err(error),
        Err(error) => {
            eprintln!("initial watch build failed: {error}");
            false
        }
    };

    let workspace = Workspace::load(options.root.clone())?;
    if let Some(path) = &normalized_config_path {
        let file = workspace.root.join(path);
        // Stock attributes an event to the deepest package. A selected root
        // AssetId physically inside a dependency is not a root config event.
        retain_configuration |= workspace
            .package_roots()
            .iter()
            .map(|root| normalized_watch_path(root))
            .any(|root| root != workspace.root && file.starts_with(root));
    }
    if initial_native_build {
        source_post_process_outputs = load_source_post_process_outputs(&workspace.root);
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
    println!(
        "Watching {} (native filesystem events)",
        workspace.root.display()
    );

    loop {
        let configuration_changed = wait_for_relevant_event(
            &receiver,
            &workspace,
            &source_post_process_outputs,
            options.interval_ms,
            stock_config_path.as_deref(),
        )?;

        eprintln!("Change detected; rebuilding");
        match run_watch_build(
            options,
            &mut pool,
            &mut pool_signature,
            &mut pool_shape,
            &mut cached_configuration,
            retain_configuration && !configuration_changed,
        ) {
            Ok(true) => {
                source_post_process_outputs = load_source_post_process_outputs(&workspace.root);
            }
            Ok(false) => source_post_process_outputs.clear(),
            Err(error) if error.kind() == io::ErrorKind::Unsupported => return Err(error),
            Err(error) => {
                eprintln!("watch build failed: {error}");
            }
        }
    }
}

fn run_watch_build(
    options: &Options,
    pool: &mut Option<WorkerPool>,
    pool_signature: &mut Option<String>,
    pool_shape: &mut Option<Vec<ConfiguredBuilder>>,
    cached_configuration: &mut Option<RustBuildConfig>,
    reuse_configuration: bool,
) -> io::Result<bool> {
    let workspace = Workspace::load(options.root.clone())?;
    let selected = if reuse_configuration && cached_configuration.is_some() {
        cached_configuration.clone()
    } else {
        select_frontend(options, &workspace)?
    };
    let Some(build_config) = selected else {
        pool.take();
        run_dart_fallback(options)?;
        return Ok(false);
    };

    // Stock 2.16.2 reloads the plan in watch, but changing application/output
    // topology does not behave like a fresh build. Do not partially emulate
    // that transition: hand the complete watch invocation to stock instead.
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
    {
        pool.take();
        let reason = "watch configuration changed builder applications or output topology";
        if options.mode == FrontendMode::Rust {
            return Err(io::Error::new(io::ErrorKind::Unsupported, reason));
        }
        eprintln!("Rust frontend unsupported ({reason}); using Dart fallback");
        run_dart_fallback(options)?;
        return Ok(false);
    }
    *pool_shape = Some(shape);
    *cached_configuration = Some(build_config.clone());
    if *pool_signature != build_config.manifest_signature {
        pool.take();
        *pool_signature = build_config.manifest_signature.clone();
    }
    if pool.is_none() {
        let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
        let worker_command = worker_executable(options, &build_config)?;
        let mut worker_pool = WorkerPool::start(
            &workspace.root,
            dart_binary,
            &worker_command,
            options.jobs,
            options.worker.is_none(),
        )?;
        worker_pool.pin_worker_artifact();
        *pool = Some(worker_pool);
    }
    build::run_with_config(options, pool.as_mut(), workspace, build_config)?;
    Ok(true)
}

fn wait_for_relevant_event(
    receiver: &Receiver<notify::Result<Event>>,
    workspace: &Workspace,
    source_post_process_outputs: &BTreeSet<String>,
    debounce_ms: u64,
    stock_config_path: Option<&str>,
) -> io::Result<bool> {
    loop {
        let event = receiver.recv().map_err(io::Error::other)?;
        let event = event.map_err(io::Error::other)?;
        if !is_relevant_event(
            workspace,
            &event,
            source_post_process_outputs,
            stock_config_path,
        ) {
            continue;
        }

        let mut configuration_changed =
            is_configuration_event(workspace, &event, stock_config_path);
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
                    ) {
                        configuration_changed |=
                            is_configuration_event(workspace, &event, stock_config_path);
                        quiet_until = Instant::now() + debounce;
                    }
                }
                Ok(Err(_)) => {}
                Err(_) => break,
            }
        }
        return Ok(configuration_changed);
    }
}

// Package-config relative URIs are stored as joined paths by Workspace. Stock
// resolves URI dot segments before assigning an event to the deepest package.
fn normalized_watch_path(path: &Path) -> PathBuf {
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

fn is_configuration_event(workspace: &Workspace, event: &Event, selected: Option<&str>) -> bool {
    event.paths.iter().any(|path| {
        let path = normalized_watch_path(path);
        let root = workspace
            .package_roots()
            .into_iter()
            .map(|root| normalized_watch_path(&root))
            .filter(|root| path.starts_with(root))
            .max_by_key(|root| root.components().count());
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

fn load_source_post_process_outputs(root: &Path) -> BTreeSet<String> {
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
    let Ok(state) = GraphState::load(&graph_path) else {
        return BTreeSet::new();
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
) -> bool {
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
        // An explicitly selected config takes precedence over generic native
        // artifact/generated-output filters, like stock's config predicate.
        if is_root_package && selected == Some(relative.replace('\\', "/").as_str()) {
            return true;
        }
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
        if components
            .first()
            .is_some_and(|component| component.as_os_str().to_str() == Some(".dart_tool"))
        {
            return is_root_package && name == "package_config.json";
        }
        if is_root_package
            && is_generated_output(
                &workspace.root,
                path,
                &workspace.root_package,
                source_post_process_outputs,
            )
        {
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
