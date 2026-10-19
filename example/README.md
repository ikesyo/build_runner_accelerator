# build_runner_accelerator example

This package replaces the usual `build_runner` command with a project-local
launcher that requires the Rust frontend and a supported workspace.

Add the package to an existing Dart package that already uses
`build_runner` and a builder package:

```bash
dart pub add dev:build_runner_accelerator
```

Run a build or watch session from that package:

```bash
dart run build_runner_accelerator build
dart run build_runner_accelerator watch
```

Execution is native-only in 0.14.0. An unavailable native binary or unsupported
request fails explicitly. The `--mode` option is removed. To use stock directly,
run `dart run build_runner build` or `dart run build_runner watch`.

See the [upgrade guide](../docs/compatibility-cleanup.md) before switching back
to native after stock execution or when legacy output-policy history exists.
