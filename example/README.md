# build_runner_accelerator example

This package replaces the usual `build_runner` command with a project-local
launcher that can use the Rust frontend when the workspace is supported.

Add the pre-release to an existing Dart package that already uses
`build_runner` and a builder package:

```bash
dart pub add dev:build_runner_accelerator:^0.1.0-dev.1
```

Run a build or watch session from that package:

```bash
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
```

The default `auto` mode falls back to stock Dart `build_runner` when native
execution is unavailable or the workspace is outside the supported native
manifest subset. Use `--mode dart` to force the fallback, or `--mode rust` to
make native frontend incompatibilities fail explicitly.
