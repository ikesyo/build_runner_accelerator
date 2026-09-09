mod assets;
mod build;
mod builder;
mod cli;
mod digest;
mod frontend;
mod graph;
mod metrics;
mod pattern;
mod plan;
mod protocol;
mod snapshot;
mod watch;
mod worker;
mod worker_kernel;
mod workspace;

use std::env;
use std::io;

fn main() -> io::Result<()> {
    let options = cli::Options::parse(env::args().skip(1))?;
    match options.command.as_str() {
        "--help" | "-h" => {
            print_usage();
            Ok(())
        }
        "--version" => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        "build" => build::run(&options, None),
        "watch" => watch::run(&options),
        "aot-cache-key" => frontend::run_aot_cache_key(&options),
        "aot-prewarm" => frontend::run_aot_prewarm(&options),
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
        "usage: build_runner_accelerator <build|watch|aot-cache-key|aot-prewarm> [--root PATH] [--dart PATH] [--worker PACKAGE:EXECUTABLE] [--jobs N] [--mode auto|rust|dart]"
    );
}
