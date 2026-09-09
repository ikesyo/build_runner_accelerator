mod assets;
mod build;
mod builder;
mod cli;
mod digest;
mod frontend;
mod graph;
mod metrics;
mod plan;
mod pattern;
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
        "build" => build::run(&options, None),
        "watch" => watch::run(&options),
        command => {
            eprintln!(
                "usage: fast_build_runner <build|watch> [--root PATH] [--dart PATH] [--worker PACKAGE:EXECUTABLE] [--jobs N] [--mode auto|rust|dart]"
            );
            Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("unsupported command: {command}"),
            ))
        }
    }
}
