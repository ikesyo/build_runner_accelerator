# Experimental AOT compiler dependency isolation

This report consolidates the AOT-cold investigation, CLI pruning and parse-API
split. Compiler dependency isolation remains disabled by default and preserves
builder execution logic. The independent default optimization for warm worker
AOT validation is documented [separately](aot-validation-digests-2026-10.md).

## Implementation and use

Build the checkout's release frontend and enable it in a consumer workspace:

```bash
BUILD_RUNNER_ACCELERATOR_BIN=/path/to/checkout/rust/target/release/build_runner_accelerator \
BUILD_RUNNER_ACCELERATOR_EXPERIMENTAL_COMPILE_ISOLATION=1 \
  dart run build_runner_accelerator build
```

[ADR 0047](../adr/0047-experimental-compile-isolation.md) defines the bounded
version window: build_runner 2.16.1/2.16.2, Analyzer 14.5.0/14.6.0 and dart_style
3.1.13/3.1.14. Unexpected versions/source shapes fail before native actions.
Original package sources and the application's config/lockfile stay unchanged.

The compiler view copies four packages, including the accelerator itself:

- Separate unchanged Analyzer parseFile/parseString implementations from
  resolveFile/context construction. Preserve the public exports and redirect
  known parse consumers to the lightweight implementation. A documentation-only
  context import becomes a docImport.
- Remove the stock CLI import from the copied process adapter. ChildProcess.run
  intentionally prints a diagnostic and exits the worker with error, so a
  builder cannot catch this unsupported call and publish success.
- Use content-addressed copies, independent default/experimental config selectors
  and mode-sensitive manifest/AOT/kernel identities. Builder-visible packages
  remain original; the legacy resolver backport composes with this experiment.

## Why this direction

On the ten-model JSON fixture, an instrumented cold build spent about 32 s of
its 36 s native command in worker AOT compilation. Manifest preparation already
starts that compilation early; another source probe would duplicate work.
A one-pair two-CPU SDK-summary prewarm screen regressed Clean from 38.755 to
52.988 s and was rejected. O1/RTA probes produced identical executables and no
useful improvement. These screens were not repeated or adopted.

The dependency closure included stock CLI code and Analyzer context discovery
through imports used only for parsing. Removing those compiler inputs is the
retained hypothesis. Full resolver/diagnostic APIs and older formatter styles
remain: builders can request those behaviors at runtime.

## Historical isolated compiler screen

One ordered control/combined pair used Dart 3.13.3, build_runner 2.16.1,
Analyzer 14.6.0, dart_style 3.1.14 and a ten-model JSON worker, two-CPU quota,
8 GiB limit. SDK/package/OS caches were warm; compiler outputs were fresh.
This probe excluded launcher, preparation/copying and build actions.

| Measurement | Control | CLI + parse prototype |
| --- | ---: | ---: |
| Unique Dart sources | 1,294 | 1,107 |
| Source bytes | 16,080,953 | 15,039,490 |
| AOT compile wall seconds | 32.135 | 31.302 |
| Executable bytes | 20,254,696 | 20,254,704 |

CLI pruning removes 175 modules; parse isolation removes 13 and adds one.
These cuts do not overlap. The observed compile difference was 0.833 s (2.6%)
in one pair, mainly in kernel generation; it does not establish synergy or a
stable speedup. Nearly identical executable sizes are consistent with the
removed code already being eliminated before final machine-code emission.

The combined executable matched stored stock outputs for clean/no-op/one-file/
broad, factory probes and triggers. That stock reference used Analyzer 14.4.0
because the old runner requires a compatibility backport with 14.6.0; it is
an output check, not a stock/native performance comparison. The prototype's
catchable CLI stub differs from the runtime adapter's fail-closed exit.

For the bounded research reproduction, use a prepared worker workspace with
these historical dependency versions and isolation disabled:

```bash
python3 scripts/probe_worker_dependencies.py \
  --workspace /path/to/prepared/json-app \
  --dart /path/to/dart-sdk/bin/dart \
  --results /tmp/aot-dependency-probe --compile
```

The results directory must be new and outside the input packages/workspace.
Omit --compile to inspect the transformation without compiling. The script
records the patch, config, commands and depfiles outside the repository. Its
restricted prototype worker is not a production replacement.

## Runtime OFF/ON comparison, three repeats (2026-10-31)

This follow-up measures the implemented experimental environment variable,
including source-copy preparation/validation and the normal Dart launcher.
It is separate from the historical isolated compiler screen above.

- Implementation: PR #161, source checkout `5e1dbbe` on main `5069081`;
  release frontend rebuilt from that checkout, Rust/Cargo 1.98.1.
- Linux x64, CPU quota 2 CPUs (`200000 100000`), memory limit 8 GiB;
  Dart 3.13.3, two workers, synchronous AOT, no manual prewarm.
- Tracked `json_serializable_10_app`: ten independent JSON models;
  build_runner 2.16.2, Analyzer 14.5.0, dart_style 3.1.13,
  json_serializable 6.14.1, build 4.0.11, source_gen 4.2.4.
  Offline pub get enforces the fixture lockfile outside the timed region.
- Three fresh workspaces per mode, empty accelerator/AOT/analyzer caches;
  SDK, resolved package and OS caches remain warm. Each workspace then runs
  no-op, one-file and broad comment-only edits with its caches retained.
- Serial order: stock reference once, OFF/ON, ON/OFF, OFF/ON. No concurrent
  builds or process polling instrumentation. Both modes use identical sources,
  native executable and worker catalog; only the environment variable differs.

Wall seconds, median (min–max), three samples per mode:

| Case | Default OFF | Experimental ON |
| --- | ---: | ---: |
| Clean (AOT-cold) | 37.977 (37.191–38.597) | 37.296 (37.146–37.567) |
| no-op | 0.265 (0.216–0.266) | 0.317 (0.266–0.365) |
| one-file | 0.418 (0.415–0.419) | 0.417 (0.417–0.470) |
| broad | 0.468 (0.418–0.469) | 0.472 (0.467–0.517) |

Clean observations in round order (seconds):

| Round | Order | OFF | ON | OFF minus ON |
| --- | --- | ---: | ---: | ---: |
| 1 | OFF, ON | 37.977 | 37.296 | 0.680 |
| 2 | ON, OFF | 38.597 | 37.567 | 1.030 |
| 3 | OFF, ON | 37.191 | 37.146 | 0.045 |

The difference between Clean medians is 0.680 s (1.8%). All three paired
observations favor ON, but the third is nearly tied and the ranges overlap.
Three pairs in one environment support a small improvement here, not a stable
cross-project speedup. Median child CPU time (user + system) is 48.066 s OFF
and 47.343 s ON. Do not pool these samples with the historical one-pair
compiler probe: versions, scope and instrumentation differ.

Warm results show a tradeoff: no-op adds about 52 ms at the median; one-file
and broad have similar medians with overlapping ranges. These cases still
validate/select compiler copies on each launch. The observations suggest that
repeated preparation/validation is worth inspecting next; they do not isolate
its cost. Keep the feature experimental and disabled by default.

All 24 native builds produced outputs byte-identical to the separate stock
reference across all four cases. Normalized manifests and generated worker
catalogs matched across modes and repeats; all native builds used published
AOT artifacts without JIT fallback. The experimental compiler identity was
present in all three ON workspaces. This checks fresh AOT mode selection and
incremental output behavior; it does not replace the dedicated mode-transition,
failure-rollback, JIT or broader-builder correctness suites.

Reproduce from the repository root after building the release frontend:

```bash
env -u HOME python3 scripts/benchmark_cold_aot.py \
  --baseline-root "$PWD" \
  --native "$PWD/rust/target/release/build_runner_accelerator" \
  --dart "$PWD/.toolchains/dart/dart-sdk/bin/dart" \
  --pub-cache "$PWD/.pub-cache" \
  --results /tmp/bra-isolation-repeat \
  --jobs 2 --repeats 3 --experimental-compile-isolation
```

The experimental harness option compares the same checkout with the flag
absent/present and runs stock once only to establish expected output bytes.
Use a new results directory for a rerun. Raw metadata, samples and logs remain
under `/tmp/bra-isolation-repeat/` and `/tmp/bra-isolation-repeat.log`; raw JSON
is intentionally not committed. No further cold performance trials were run at this stage.


## Reducing warm preparation overhead

The initial adapter reread roughly 800 source files (about 11 MB), reran the
transformations/content hashing, and reread the compiler copies on every load.
It now persists a disposable validation receipt after a full successful check.
On Unix, unchanged source and copy metadata permits reusing the existing
selector without reading source contents, transforming or hashing them again.

The receipt binds the complete incoming package config, canonical package roots
and transformation revision. Each file/directory records device, inode, mode,
size, nanosecond mtime and ctime. Directory metadata detects additions/deletions;
ctime also detects same-size writes with restored mtime. The selector is checked
too. Missing/malformed receipts or metadata changes take the original full
validation path; damaged known copy contents still fail before compilation.
Metadata is captured before content validation and checked again before saving
a receipt, so observed concurrent changes do not authorize reuse. Non-Unix
platforms retain full content validation. Cache files are disposable local
state, not an adversarial integrity boundary; this relies on coherent Unix
filesystem change-time semantics.

A focused warm comparison reused the already compiled AOT workspaces from the
previous section. No AOT compilation was needed. All lanes used two workers,
the same real SDK, inputs and published AOT artifacts. OFF and updated ON used
the new release frontend; previous ON used the saved `935bfe6` release binary.
Source-copy identity and generated worker code did not change.

Native-command no-op wall seconds, five samples per lane in rotating order:

| Lane | Median | Min–max |
| --- | ---: | ---: |
| OFF | 0.007656 | 0.007615–0.007737 |
| Previous ON | 0.064011 | 0.063882–0.067675 |
| Updated ON | 0.015797 | 0.015735–0.015914 |

Relative to OFF, the added native-command cost falls from 56.4 ms to 8.1 ms,
about an 86% reduction. Metadata checks still scale with the selected source
and copy files; this is not zero overhead. Eliminating them would need a
separate invalidation mechanism or weaker source-change detection.

Normal Dart-launcher wall seconds, median of three samples per lane/case:

| Case | OFF | Previous ON | Updated ON |
| --- | ---: | ---: | ---: |
| no-op | 0.215530 | 0.264972 | 0.265310 |
| one-file | 0.416281 | 0.417014 | 0.417607 |
| broad | 0.467880 | 0.516787 | 0.466349 |

Each lane starts with an unmeasured warm invocation; order rotates by round.
The edits append comments to one/all ten inputs; every measured invocation
checks generated bytes. All 27 launcher and 15 direct-native observations
matched the previous stock reference outputs. Launcher no-op observations do
not demonstrate an end-to-end improvement despite the lower native cost;
retain both results rather than claiming that the original 52 ms disappeared.
The initial warm diagnostic overlapped a Clippy check and was discarded;
the reported comparison ran without concurrent compilation. Cold performance
was not remeasured for this preparation-only change.

For this focused comparison, reuse the cold harness's `0-baseline`,
`0-candidate` and `1-candidate` workspaces for OFF, previous ON and updated ON.
Set the same cache/analyzer paths recorded by that harness and use the original
release binary for previous ON. Run the documented build command three times
per case/lane in rotating order. The native measurement invokes the selected
release frontend directly with `build --dart <same Dart> --jobs 2`, five no-op
samples per lane. Raw scripts/samples/logs remain outside Git:
`/tmp/bra-warm-validation-final{.py,.log,/}` and
`/tmp/bra-native-warm-validation{.py,.log,/}`.


## Independent warm validation optimization

The [AOT digest-reuse follow-up](aot-validation-digests-2026-10.md) improves warm
build preparation without compiler dependency isolation. Its default-path
measurements and regression tests are kept in that separate report. Those warm
gains apply with the experimental flag disabled and should not be attributed
to the compiler-source split.
