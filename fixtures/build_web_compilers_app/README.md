# Published web compiler probe

This single-package probe pins the unmodified published
`build_web_compilers` 4.8.12 and stock `build_runner` 2.16.2. It uses Dart
3.13.3, `compiler: dart2js`, `dart2js_args: [-O1]`, dev configuration, and
`generate_for: [web/**.dart]`. The public post-process option
`dart2js_archive_extractor.filter_outputs: true` is explicitly enabled.
No dependency overrides are used. Production
constraints are unchanged. DDC, hot reload, dart2wasm, deferred loading,
release configuration and multi-package/workspace compatibility are separate
research scopes.

## Published contract

The pub.dev package metadata requires SDK `>=3.13.0 <3.15.0-z`, Analyzer
`>=13.3.0 <15.0.0`, build `>=2.0.0 <5.0.0`, and build_runner `^2.0.0`.
The lockfile records the actual solution. The downloaded archive SHA-256 is
`0c41652721f5ae373028e13e140806867b7cb73ee00df18d48cf6b5386cbe090`.
Sources: <https://pub.dev/api/packages/build_web_compilers/versions/4.8.12>
and <https://pub.dev/api/archives/build_web_compilers-4.8.12.tar.gz>.

Read `build.yaml`, `lib/builders.dart`, `lib/src/web_entrypoint_builder.dart`,
`lib/src/dart2js_bootstrap.dart`, `lib/src/archive_extractor.dart`, and
`lib/src/build_modules/` from that archive to reproduce the investigation.
The former build_modules implementation is bundled within this package.

- `module_library` parses source directives without requesting a Resolver.
- The optional dart2js factories produce raw/clean meta modules from `$lib$`
  and per-library `.dart2js.module` assets. Meta-module collection uses
  `findAssets('**.module.library')`; reads demand optional producers.
- The entrypoint builder parses the input to detect `main`, reads module
  metadata and transitive Dart sources, and uses a Resource-managed scratch
  space. It invokes SDK `bin/dart compile js` with the multi-root filesystem,
  a generated package config, and SDK `lib/libraries.json`.
- Entry JS and map are explicit cache outputs. Other compiler outputs are
  archived; archive entries include filesystem mode and mtime. The public
  post-process extractor emits dynamic cache outputs and deletes its input.
  `module_cleanup` logically removes module metadata. Physical stock cache
  retention must be distinguished from logical readability.
- DDC-related factories remain publicly applied but optional and must not be
  assumed to execute merely because they are present. The entrypoint marker
  is a no-op with hot reload disabled. SDK JS compilation/copy is for DDC.

The selected mode avoids DDC's kernel worker, SDK JS and frontend-server
requirements while exercising real compilation and the optional module chain.
This choice does not imply support for those other modes.

## Comparison boundary

For each live entrypoint the current public cache outputs are `.dart.js` and
`.dart.js.map`. The source tree has no generated outputs in this mode. Source
file sets/bytes are compared too. There are no DDC bootstrap, kernel, digest,
module JS, or wasm outputs in this configuration. Module metadata is generated
input to the compiler chain, not a final public output.

The comparison reads stock graph format 47 to determine current logical
outputs, applies the documented cleanup input contract to the native cache,
and compares the complete remaining native file set and raw bytes. It also
compares retained module metadata bytes where both physical caches contain the
same path. Stale JS/maps cannot be hidden by the intermediate exclusion.
No output bytes are normalized.

Stock retains physical `.module.library`, raw/clean meta modules,
`.dart2js.module`, and `.dart.js.tar.gz` files after logical cleanup. Native can
retain the same intermediate files. Raw archives **do not match**: the tar
entry mtime comes from filesystem metadata and `.deps` includes the random
scratch directory plus SDK paths (the native AOT SDK facade differs too).
The default dev extractor exposes `.deps`, so that configuration is outside
this byte-identical claim. The selected `filter_outputs: true` discards `.deps`
and logically deletes the archive using the unmodified public builder.
Normalizing paths or times is not counted as raw byte equality.

## Validation

Run sequentially with one SDK and Pub cache:

```bash
bash scripts/correctness_web_compilers.sh
bash scripts/watch_smoke_web_compilers.sh
```

The scripts set `BUILD_MAX_WORKERS_PER_TASK=1` and native `--jobs 1`. They keep
logs outside watched workspaces and retain failed workspaces for diagnosis.
The paired watch script selects synchronous worker AOT
(`BUILD_RUNNER_ACCELERATOR_WORKER_AOT=force`); callers can explicitly override it.
Cold background-AOT watch selected a script worker and did not complete the
initial build within the 600-second CI wait. That execution configuration is
outside this fixture's completed validation scope.
Use the repository toolchain overrides as described in `docs/development.md`.
On the managed environment used here, source `.toolchains/task-env.sh`, select
SDK `bin/dart-cloud`, and run the scripts with `env -u HOME` so the compiler
subprocess shares the wrapper's writable analytics/cache behavior. This is an
environment setup detail, not a dependency override or compiler-source patch.

Initial clean/no-op, non-target, library and entrypoint changes matched raw
public bytes on Dart 3.13.3 / Rust 1.98.1. Lifecycle, compiler failure/recovery,
watch and mandatory verification are in progress; this is not yet a completed
compatibility claim.
