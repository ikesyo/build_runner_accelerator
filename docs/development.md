# Development

The repository is tested with a locally selected Dart SDK, Rust toolchain, and
pub cache. Do not rely on a different global SDK when comparing stock
`build_runner` with the native frontend.

## Toolchain selection

Repository scripts resolve tools in the following order:

1. An explicit environment variable such as `DART_BIN` or `CARGO_BIN`.
2. The repository-local toolchain under `.toolchains/`, when present.
3. The corresponding executable on `PATH`.

The cache and Rust home variables can also be overridden explicitly:

```bash
export DART_BIN=/absolute/path/to/dart
export CARGO_BIN=/absolute/path/to/cargo
export PUB_CACHE=/absolute/path/to/pub-cache
export RUSTUP_HOME=/absolute/path/to/rustup
export CARGO_HOME=/absolute/path/to/cargo-home
```

AOT-specific scripts that inspect SDK files also accept `DART_SDK`.

The 0.1.x package line supports Dart `>=3.11.0 <4.0.0`. Its tested core build
stack is bounded as follows:

- `analyzer >=13.3.0 <15.0.0`
- `build >=4.0.9 <5.0.0`
- `build_config >=1.3.2 <1.4.0`
- `build_runner >=2.16.1 <2.17.0`
- `package_config >=2.2.0 <4.0.0`

The `build_runner` upper bound is intentional: the worker uses private
`build_runner` interfaces whose signatures changed in 2.15.x and may change
again in later minor releases. The release workflow validates a minimum solution with Dart
3.11.0 and `dart pub downgrade`, and a current solution with Dart 3.13.3 and
`dart pub upgrade`. Rust contributors should use the stable toolchain selected
by the repository's build environment.

## Local checks

```bash
dart pub get
dart analyze
dart test
cargo test --manifest-path rust/Cargo.toml
```

The default verification loop builds the frontend once and reuses it:

```bash
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
VERIFY_LEVEL=full bash scripts/verify.sh
```

Run the relevant fixture scripts when changing graph, worker, watch, or
builder behavior:

```bash
bash scripts/watch_smoke.sh
bash scripts/benchmark_matrix.sh
```

For performance changes, enable
`BUILD_RUNNER_ACCELERATOR_METRICS=1` and record clean, no-op, one-file, and
broad incremental cases. Keep raw JSONL and trace artifacts local. Update
the public summary in [`benchmarks.md`](benchmarks.md) only from a
reproducible launcher-inclusive run; detailed experiments belong in
[`benchmarks/experiments-2026-09.md`](benchmarks/experiments-2026-09.md).

## Release checks

The release workflow builds one archive per target in
[`doc/launcher-and-release.md`](../doc/launcher-and-release.md), checks the
native `--version` and `--help` paths, then creates the signed manifest and
checksums. The signing private key must only be supplied through the CI secret;
the public key is pinned in the Dart package.
