# Published DDC probe

This single-root-package probe pins published `build_web_compilers` 4.8.12,
stock `build_runner` 2.16.2, Dart 3.13.3, dev configuration,
`compiler: dartdevc`, `generate_for: [web/**.dart]`, and hot reload disabled.
The root package name deliberately matches the adjacent dart2js fixture so the
same source and dependency solution can exercise a different compiler chain.
No hosted sources or production dependency constraints are modified.
The lockfile resolves build 4.0.11 and Analyzer 14.6.0 without overrides.

## Implementation evidence

The unmodified pub.dev archive has SHA-256
`0c41652721f5ae373028e13e140806867b7cb73ee00df18d48cf6b5386cbe090`.
Sources: [metadata](https://pub.dev/api/packages/build_web_compilers/versions/4.8.12)
and [archive](https://pub.dev/api/archives/build_web_compilers-4.8.12.tar.gz).
Read its `build.yaml`, `lib/builders.dart`, `lib/src/dev_compiler_builder.dart`,
`lib/src/dev_compiler_bootstrap.dart`, `lib/src/sdk_js_compile_builder.dart`,
`lib/src/sdk_js_copy_builder.dart`, and `lib/src/build_modules/`.

The entrypoint option selects `dartdevc` (DDC), not `dart2js`. With hot reload
false, the entrypoint marker returns without output and `ddcBuilder` creates
`DevCompilerBuilder`. The selected defaults are `use-incremental-compiler: true`,
`track-unused-inputs: true`, `generate-full-dill: false`,
`emit-debug-symbols: false`, `canary: false` and
`ddc-library-bundle: false`. The default module system is AMD; library bundles
and the hot-reload frontend server are outside this probe.

The optional chain is directive parsing (`.module.library`), DDC raw/clean
meta modules on virtual `lib/$lib$`, per-library `.ddc.module`, kernel summaries
and module JavaScript. Meta modules enumerate generated module libraries with
`findAssets`; subsequent reads demand optional producers. The kernel and JS
builders each consume `.ddc.module` in distinct configured phases. Only modules
whose primary source matches that input produce compiler outputs. The
entrypoint bootstrap demands SDK resources and its transitive JS modules,
reads metadata and digests JS. Factory declaration alone does not prove demand.
The runtime factory mappings
split `ddc` into kernel-only and JS actions, and `sdk_js` into compile/copy
actions. Entrypoint's runtime mapping includes `.dart.bootstrap.end.js`, absent
from the published static `build.yaml` output list; stock uses the instantiated
builder mapping. The existing shared runtime-mapping probe handles this without
a package-specific output exception.
These builders parse directives and use asset reads, rather than a Resolver.

Resources include decoded module/meta-module caches, scratch space, persistent
DDC and common-frontend worker drivers. Scratch space creates a multi-root
package config. DDC starts SDK `bin/dart --suppress-analytics compile js-dev
--persistent_worker`; kernel summaries use `bin/dartaotruntime` with
`bin/snapshots/kernel_worker_aot.dart.snapshot --persistent_worker`. SDK JS
compilation uses a separate `dart compile js-dev` process and
`lib/_internal/ddc_platform.dill`; module compilation uses
`lib/_internal/ddc_outline.dill` and `lib/libraries.json`. Runtime copies come
from SDK
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

## Validation

The stock build is observed before native comparison. The initial successful
stock/native pair matched the complete 16-file set and raw bytes, including
kernel, module/SDK maps, metadata and digests. Ordered root/SDK factory inputs
and generated module-library glob members matched too. No Resolver was used.
Run the regression with:

```bash
bash scripts/correctness_web_compilers_ddc.sh
bash scripts/watch_smoke_web_compilers_ddc.sh
```

Use one SDK/cache; source `.toolchains/task-env.sh` in the managed environment,
select SDK `bin/dart-cloud`, and invoke with `env -u HOME`. Compiler jobs are 1,
Cargo jobs 2. Logs stay outside watched trees. Public output sets and raw bytes
must be compared separately from retained, logically deleted module metadata.
No path/time/order normalization counts as raw-byte equality. The published
builders themselves run `fixAndCopySourceMap` and `fixMetadataSources` before
writing outputs. Their emitted browser paths/metadata and this fixture's
canonical kernel bytes match despite separate scratch roots and the native
AOT SDK facade. The comparison does not rewrite any file. Retained module
metadata present at the same physical paths is compared separately; this is
not an equality claim for entire private cache trees or graph formats.

The first native attempt failed before publication because physical-source
collection defaults also constrained action target scope, omitting dependency
`$package$` SDK producers. Stock `BuildPhaseCreator` passes raw target `sources`
to `InputMatcher` for actions; collection separately applies package defaults.
The shared manifest now preserves that distinction and invalidates older
manifests. The next attempt exposed concurrent asset RPC writes/reader
ownership when DDC bootstrap demands modules via `Future.wait`. Complete frames
and per-action round trips are now queued; nested optional actions have separate
sessions. These are shared fixes, with no package-name branches.

The build regression passed all nine successful comparisons: clean/no-op,
non-target, dependency library and entrypoint edits, add, rename, delete and
recovery. Each compares the complete current public set and raw bytes; generated
module candidates/input order and configured chain order are also checked.
Removing/renaming the added library and entrypoint removes stale public module,
kernel and bootstrap outputs. No full dill, symbols or hot-reload marker is
produced by this configuration.

The failure case uses an actual undefined identifier in the dependency library
and adds an independent entrypoint. Both real compilers fail; stock can publish
the independent entrypoint while native cache bytes and graph remain exactly
at their preceding successful state. Repairing the identifier restores complete
raw equality. This is the all-success commit boundary, not crash atomicity.

CI run [811](https://github.com/ikesyo/build_runner_accelerator/actions/runs/39636219783)
passed, including the DDC build and AOT paired watch probes and existing related
compatibility checks. Local AOT paired watch also passed library/entrypoint
change, add, rename, delete and real compiler failure/atomic recovery with raw
output equality. Linux process observations confirmed both stock and native
SDK JS compiler, DDC worker and kernel worker inherited `HOME` unset, the same
explicit `PUB_CACHE`, and `BUILD_MAX_WORKERS_PER_TASK=1`; SDK/DDC commands used
`--suppress-analytics`. No `/tmp` environment configuration file was used.
Both mandatory local quick commands passed: ordinary quick (2492 seconds) and
`VERIFY_ARBITRARY_BUILDER=1` quick (3099 seconds), including the arbitrary-only
tail. The previous #127 local timeout failures remain historical failures;
these new runs do not change their recorded outcome. Generic watch passed
(333 seconds), as did Dart analysis, Rust clippy and Rust tests (155 passed,
one ignored). No production timeout or dependency constraints were changed.
Local full validation selected `compatibility-graph`; this is not a claim that
every full suite was run locally. The complete CI workflow passed.

The first four mapping lanes took 386/322/380/386 seconds;
moving the measured 47-second multiple-mapping probe to the shorter second lane
produced 391/383/342/397 seconds in run 811.
No jobs or parallel lanes were added. These timings guide test distribution;
no product performance improvement is claimed.

The claim is limited to this pinned configuration and tested inputs. Hot reload,
library bundles/frontend server, other compiler flags (full kernel, symbols,
canary, environment definitions, nonincremental compilation), conditional-import
pruning, other package/SDK versions and full workspaces are unvalidated.
