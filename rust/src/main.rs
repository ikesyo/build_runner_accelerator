mod assets;
mod build;
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
    if !options.native_supported() || options.mode == cli::FrontendMode::Dart {
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
            eprintln!("Rust frontend disabled (--mode dart); nothing to prewarm");
            return Ok(());
        }
        return frontend::run_dart_fallback(&options);
    }
    if options
        .stock_arguments
        .iter()
        .any(|arg| arg == "--force-aot")
    {
        // Single-threaded startup, before any workers are spawned.
        unsafe {
            env::set_var("BUILD_RUNNER_ACCELERATOR_WORKER_AOT", "force");
        }
    } else if options
        .stock_arguments
        .iter()
        .any(|arg| arg == "--force-jit")
    {
        unsafe {
            env::set_var("BUILD_RUNNER_ACCELERATOR_WORKER_AOT", "0");
        }
    }
    match options.command.as_str() {
        "build" => {
            let _wall = wall::Session::new();
            worker_kernel::apply_default_worker_aot_policy(&options.command);
            build::run(&options, None)
        }
        "watch" => {
            worker_kernel::apply_default_worker_aot_policy(&options.command);
            watch::run(&options)
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
        "usage: build_runner_accelerator <build|watch|prewarm|aot-cache-key> [--root PATH] [--dart PATH] [--worker PACKAGE:EXECUTABLE] [--jobs N] [--mode auto|rust|dart] [--background] [--force-aot|--force-jit] [--delete-conflicting-outputs|-d]\n--worker is an internal artifact override for tests/diagnostics, not a third-party extension API.\nUnsupported stock commands/options: auto/dart forward unchanged; rust rejects. --build-filter uses stock. -- stops accelerator option parsing."
    );
}
