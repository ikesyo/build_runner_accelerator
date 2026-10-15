mod assets;
mod build;
mod build_filter;
mod builder;
mod cli;
mod digest;
mod frontend;
mod graph;
mod manifest_generator;
mod metrics;
mod pattern;
mod plan;
mod process;
mod protocol;
mod snapshot;
mod visibility;
mod wall;
mod watch;
mod worker;
mod worker_kernel;
mod workspace;
mod workspace_lock;

use std::env;
use std::io;

fn main() -> io::Result<()> {
    if let Some(code) = process::supervise()? {
        std::process::exit(code);
    }
    let options = cli::Options::parse(env::args().skip(1))?;
    if options.stock_arguments.is_empty() {
        match options.command.as_str() {
            "--help" | "-h" => {
                print_usage();
                return Ok(());
            }
            "--version" => {
                println!("{}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            _ => {}
        }
    }
    let missing_config = if options.native_supported() && options.mode != cli::FrontendMode::Dart {
        cli::BuildSettings::parse(&options.stock_arguments)?
            .config_path()?
            .filter(|name| !options.root.join(name.clone()).is_file())
    } else {
        None
    };
    if let Some(name) = &missing_config {
        eprintln!("configuration file not found: {name}");
    }
    if !options.native_supported()
        || options.mode == cli::FrontendMode::Dart
        || missing_config.is_some()
    {
        if options.mode == cli::FrontendMode::Rust || options.command == "aot-cache-key" {
            return Err(io::Error::other(format!(
                "native frontend unsupported command or arguments: {} {:?}; use --mode auto or dart",
                options.command, options.stock_arguments
            )));
        }
        if options.command == "prewarm" {
            if !options.native_supported() {
                return Err(io::Error::other("prewarm does not accept stock arguments"));
            }
            eprintln!("Rust frontend unavailable or disabled; nothing to prewarm");
            return Ok(());
        }
        return frontend::run_dart_fallback(&options, None);
    }
    // Reject a competing native writer instead of falling back to a stock
    // process which would mutate the same output tree. Keep this guard through
    // late fallback and throughout a resident watch session.
    let workspace_lock = match options.command.as_str() {
        "build" | "watch" => Some(workspace_lock::WorkspaceLock::acquire(&options.root)?),
        _ => None,
    };
    let settings = cli::BuildSettings::parse(&options.stock_arguments)?;
    if settings.force_aot {
        // Single-threaded startup, before any workers are spawned.
        unsafe {
            env::set_var("BUILD_RUNNER_ACCELERATOR_WORKER_AOT", "force");
        }
    } else if settings.force_jit {
        unsafe {
            env::set_var("BUILD_RUNNER_ACCELERATOR_WORKER_AOT", "0");
        }
    }
    match options.command.as_str() {
        "build" => {
            let _wall = wall::Session::new();
            worker_kernel::apply_default_worker_aot_policy(&options.command);
            build::run(&options, None, workspace_lock.as_ref())
        }
        "watch" => {
            worker_kernel::apply_default_worker_aot_policy(&options.command);
            watch::run(&options, workspace_lock.as_ref())
        }
        "aot-cache-key" => frontend::run_aot_cache_key(&options),
        "prewarm" => frontend::run_aot_prewarm(&options),
        command => {
            print_usage();
            Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("unsupported command: {command}"),
            ))
        }
    }
}

fn print_usage() {
    eprintln!(
        "usage: build_runner_accelerator <build|watch|prewarm|aot-cache-key> [--root PATH] [--dart PATH] [--worker PACKAGE:EXECUTABLE] [--jobs N] [--mode auto|rust|dart] [--background] [--force-aot|--force-jit] [--delete-conflicting-outputs|-d] [--define BUILDER=OPTION=VALUE] [--release|--no-release|-r] [--config NAME|-c NAME] [--build-filter PATH]\nSettings apply to build/watch/prewarm. Development is default; last release/config wins; duplicate defines fail. -cNAME and grouped -rd/-dr follow stock parsing; config uses AssetId path normalization.\nWatch application/output topology changes use stock (auto) or error (rust).\n--worker is an internal artifact override for tests/diagnostics, not a third-party extension API.\nUnsupported stock commands/options: auto/dart forward unchanged; rust rejects. --build-filter: build/watch, repeated/comma-separated OR; relative/package:/asset: paths, * and whole ** segments. Dependency producers run on demand with all sibling outputs. Optional/post-process/zero-output/trigger-only or complex URI/glob syntax uses stock (rust errors). Configuration changes removing prior output applications or lacking ordered stock input/glob evidence also use stock; other filtered configuration changes without stock plan-compatibility evidence use stock. Incremental cyclic resolver reuse uses stock. Unselected outputs can disappear on later builds/watch restarts. -- stops accelerator option parsing."
    );
}
