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
mod placeholders;
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
    if options.show_help {
        print_usage();
        return Ok(());
    }
    if options.show_version {
        println!("{}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if !options.native_supported() {
        return frontend::unsupported(&format!(
            "unsupported command or arguments: {} {:?}",
            options.command, options.build_arguments
        ));
    }
    if matches!(options.command.as_str(), "build" | "watch")
        && options
            .root
            .join(frontend::STOCK_OUTPUT_POLICY_STATE)
            .exists()
    {
        return frontend::unsupported(
            "legacy stock output-policy history cannot be reused; stop all builders and reset both build states as described in docs/compatibility-cleanup.md#safe-recovery",
        );
    }
    // Hold exclusive ownership throughout native execution, including watch.
    let _workspace_lock = match options.command.as_str() {
        "build" | "watch" => Some(workspace_lock::WorkspaceLock::acquire(&options.root)?),
        _ => None,
    };
    let settings = &options.settings;
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
            build::run(&options)
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
    print!(
        r#"build_runner_accelerator <build|watch|prewarm|aot-cache-key> [options]
Native execution only. Unsupported requests fail; run dart run build_runner directly if needed.
--mode was removed in 0.14.0; remove it from scripts and CI.
Options: --root PATH --dart PATH --jobs N --interval-ms N --worker PACKAGE:EXECUTABLE
--background (prewarm only), --force-aot | --force-jit
--define BUILDER=OPTION=VALUE --release | --no-release | -r --config NAME | -c NAME
--build-filter PATH (build/watch), --only-check | --keep-modified-outputs (build only)
--delete-conflicting-outputs | -d (retired; no effect), --help | -h, --version
Output policies and filters support the validated normal-builder demand subset.
Unsupported manifest/state/API transitions fail before output/graph publication.
Watch topology changes and watch after retained output history are unsupported.
Legacy stock output-policy history requires explicit recovery; see docs/compatibility-cleanup.md#safe-recovery.
"#
    );
}
