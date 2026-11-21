fn main() {
    if let Err(error) = build_runner_accelerator::run_cli() {
        eprintln!("build_runner_accelerator: {error}");
        std::process::exit(1);
    }
}
