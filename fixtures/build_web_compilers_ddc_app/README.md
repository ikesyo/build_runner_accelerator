# Published DDC probe

This probe starts with one root package, published `build_web_compilers` 4.8.12,
stock `build_runner` 2.16.2, Dart 3.13.3, dev configuration,
`compiler: dartdevc`, `generate_for: [web/**.dart]`, and hot reload disabled.
The root package name deliberately matches the adjacent dart2js fixture so the
same source and dependency solution can exercise a different compiler chain.
No hosted sources or production dependency constraints are modified.
The lockfile resolves build 4.0.11 and Analyzer 14.6.0 without overrides.

## Implementation evidence

The unmodified pub.dev archive has SHA-256
`0c41652721f5ae373028e13e140806867b7cb73ee00df18d48cf6b5386cbe090`.
Read its `build.yaml`, `lib/builders.dart`, `lib/src/dev_compiler_builder.dart`,
`lib/src/dev_compiler_bootstrap.dart`, `lib/src/sdk_js_compile_builder.dart`,
`lib/src/sdk_js_copy_builder.dart`, and `lib/src/build_modules/`.

The entrypoint option selects `dartdevc` (DDC), not `dart2js`. With hot reload
false, the entrypoint marker returns without output and `ddcBuilder` creates
`DevCompilerBuilder`, not `DdcFrontendServerBuilder`. The selected defaults are `use-incremental-compiler: true`,
`track-unused-inputs: true`, `generate-full-dill: false`,
`emit-debug-symbols: false`, `canary: false` and
`ddc-library-bundle: false`. The default module system is AMD; library bundles and the frontend server are outside this probe.

The optional chain is directive parsing (`.module.library`), DDC raw/clean
meta modules on virtual `lib/$lib$`, per-library `.ddc.module`, kernel summaries
and module JavaScript. Meta modules enumerate generated module libraries with
`findAssets`; subsequent reads demand optional producers. The kernel and JS
builders each consume `.ddc.module` in distinct configured phases. Only modules
whose primary source matches that input produce compiler outputs. The
entrypoint bootstrap demands SDK resources and its transitive JS modules,
reads metadata and digests JS. Factory declaration alone does not prove demand.
These builders parse directives and use asset reads, rather than a Resolver.

Resources include decoded module/meta-module caches, scratch space, persistent
DDC and common-frontend worker drivers. Scratch space creates a multi-root
package config. DDC starts SDK `bin/dart --suppress-analytics compile js-dev
--persistent_worker`; kernel summaries use `bin/dartaotruntime` with
`bin/snapshots/kernel_worker_aot.dart.snapshot --persistent_worker`. SDK JS
compilation uses a separate `dart compile js-dev` process and
`lib/_internal/ddc_platform.dill`; module compilation uses
`lib/_internal/ddc_outline.dill` and `lib/libraries.json`. Runtime copies come from SDK
`lib/dev_compiler/amd/require.js` and
`lib/dev_compiler/ddc/ddc_module_loader.js`. Child processes inherit the parent
analytics/cache environment. Hot reload's frontend-server path is not exercised.

## Initial stock artifact contract

The first stock build produced 16 current logical outputs, all in the cache:

| Producer / asset | Current artifacts |
| --- | --- |
| `lib/message` module | `.ddc.dill`, `.ddc.js`, `.ddc.js.map`, `.ddc.js.metadata` |
| `web/main` module | `.ddc.js`, `.ddc.js.map`, `.ddc.js.metadata` |
| `web/main` entrypoint | `.dart.js`, `.dart.bootstrap.js`, `.dart.bootstrap.end.js`, `.digests`, `.dart.ddc_merged_metadata` |
| `build_web_compilers:lib/src/dev_compiler/` | `dart_sdk.js`, `dart_sdk.js.map`, `require.js`, `ddc_module_loader.js` |

The AMD bootstrap-end file is present with zero bytes. Only the dependency
library summary was demanded; no entrypoint `.ddc.dill` was emitted. No full
kernel, debug symbols, `.errors`, tar, wasm, source-tree output, or hot-reload
marker was emitted. `module_cleanup` logically deleted the six module-library,
raw/clean meta-module and per-library module artifacts; physical stock cache
files remain. The disabled source cleanup preserves Dart sources/maps/metadata.
The sdk copy factory writes both loaders even though AMD only needs require.js.

## Validation in progress

The stock build is observed before native comparison. Run the regression with:

```bash
bash scripts/correctness_web_compilers_ddc.sh
bash scripts/watch_smoke_web_compilers_ddc.sh
```

Use one SDK/cache; source `.toolchains/task-env.sh` in the managed environment,
select SDK `bin/dart-cloud`, and invoke with `env -u HOME`. Compiler jobs are 1,
Cargo jobs 2. Logs stay outside watched trees. Public output sets and raw bytes
must be compared separately from retained, logically deleted module metadata.
No path/time/order normalization counts as raw-byte equality.

This guide will record the observed artifact set, lifecycle results and any
remaining differences after actual compiler runs. No compatibility completion
is claimed by the source investigation alone.
