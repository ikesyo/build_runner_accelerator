mod assets;
mod build;
mod build_filter;
mod builder;
mod cli;
mod digest;
mod file_stamp;
mod frontend;
mod graph;
mod manifest_generator;
mod metrics;
mod pattern;
mod placeholders;
mod plan;
mod process;
mod protocol;
mod runner_compatibility;
mod shared_library;
mod snapshot;
mod validated_digest;
mod visibility;
mod wall;
mod watch;
mod worker;
mod worker_kernel;
mod workspace;
mod workspace_discovery;
mod workspace_lock;
mod workspace_mode;

use std::env;
use std::io;

fn main() -> io::Result<()> {
    if let Some(code) = process::supervise()? {
        std::process::exit(code);
    }
    let mut options = cli::Options::parse(env::args().skip(1))?;
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
    let original_root = options.root.clone();
    let discovery = if options.settings.workspace {
        if env::var("BUILD_RUNNER_ACCELERATOR_PLAN_ONLY").as_deref() == Ok("1") {
            return frontend::unsupported(
                "--workspace is not supported with plan-only diagnostics",
            );
        }
        Some(workspace_discovery::discover(
            &original_root,
            options.dart_binary.as_deref().unwrap_or("dart"),
        )?)
    } else {
        None
    };
    if let Some(info) = &discovery {
        options.root = info.root.clone();
        if !info.build_workspace {
            // Stock treats --workspace outside a Pub workspace as a single
            // package build; keep the same graph/configuration identity.
            options.settings.workspace = false;
        }
    }
    let _coordination = if discovery.as_ref().is_some_and(|info| info.build_workspace) {
        Some(workspace_lock::WorkspaceCoordination::acquire(
            &options.root,
            true,
        )?)
    } else if options.command == "prewarm" {
        let root = workspace_mode::coordination_root(&options.root)?;
        Some(workspace_lock::WorkspaceCoordination::acquire(
            &root, false,
        )?)
    } else {
        None
    };
    // Hold exclusive ownership throughout native execution, including watch.
    let _workspace_lock = match options.command.as_str() {
        "build" | "watch" => Some(if let Some(info) = &discovery {
            if info.build_workspace {
                workspace_lock::WorkspaceLock::acquire_all(
                    info.output_packages
                        .values()
                        .map(std::path::PathBuf::as_path),
                )?
            } else {
                workspace_lock::WorkspaceLock::acquire(&options.root)?
            }
        } else {
            workspace_lock::WorkspaceLock::acquire(&options.root)?
        }),
        _ => None,
    };
    if matches!(options.command.as_str(), "build" | "watch") {
        if let Some(info) = &discovery {
            if info.build_workspace {
                let checked = workspace_discovery::discover(
                    &original_root,
                    options.dart_binary.as_deref().unwrap_or("dart"),
                )?;
                if checked != *info {
                    return frontend::unsupported(
                        "workspace configuration changed while acquiring locks; retry",
                    );
                }
                options.workspace_output_packages = info.output_packages.clone();
                for root in info.output_packages.values() {
                    if root.join(frontend::STOCK_OUTPUT_POLICY_STATE).exists() {
                        return frontend::unsupported(
                            "legacy stock output-policy history cannot be reused; follow docs/compatibility-cleanup.md#safe-recovery",
                        );
                    }
                }
                workspace_mode::prepare(info)?;
            } else {
                workspace_mode::reject_individual_after_workspace(&options.root)?;
            }
        } else {
            workspace_mode::reject_individual_after_workspace(&options.root)?;
        }
        if options
            .root
            .join(frontend::STOCK_OUTPUT_POLICY_STATE)
            .exists()
        {
            return frontend::unsupported(
                "legacy stock output-policy history cannot be reused; stop all builders and reset both build states as described in docs/compatibility-cleanup.md#safe-recovery",
            );
        }
    }
    if options.command == "prewarm" {
        workspace_mode::reject_individual_after_workspace(&options.root)?;
    }
    if matches!(options.command.as_str(), "build" | "watch") && !options.settings.only_check {
        options.settings.legacy_keep_modified_outputs =
            runner_compatibility::legacy_output_defaults(&options.root)?;
    }
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
        r#"build_runner_accelerator <build|watch|prewarm> [options]
Native execution only. Unsupported requests fail; run dart run build_runner directly if needed.
--mode was removed in 0.14.0; remove it from scripts and CI.
Options: --root PATH --dart PATH --jobs N --interval-ms N --worker PACKAGE:EXECUTABLE
--background (prewarm only), --force-aot | --force-jit
--define BUILDER=OPTION=VALUE --release | --no-release | -r --config NAME | -c NAME
--enable-experiment NAME (repeat or comma-separate)
--build-filter PATH (build/watch), --only-check | --keep-modified-outputs (build only)
--workspace (build only; non-optional builders, no filters/policies/config/defines)
--delete-conflicting-outputs | -d (retired; no effect), --help | -h, --version
Output policies and filters support the validated normal-builder demand subset.
Unsupported manifest/state/API transitions fail before output/graph publication.
Watch topology changes and watch after retained output history are unsupported.
Legacy stock output-policy history requires explicit recovery; see docs/compatibility-cleanup.md#safe-recovery.
"#
    );
}
