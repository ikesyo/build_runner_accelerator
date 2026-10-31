# Worker AOT validation digest reuse (2026-10-31)

Warm builds rehashed a roughly 20 MB AOT executable and around a thousand
compiler dependencies whenever selecting a worker. Unix now reuses locally
validated digests when device/inode/mode/size and nanosecond mtime/ctime match,
along with the expected digest from AOT metadata. Other platforms retain full
hashing. This is independent of compiler dependency isolation and has no
experimental flag. See [ADR 0005](../adr/0005-performance-and-validation-policy.md).

Missing/malformed receipts, changed files and changed expected digests require
full reads/hashing; observed edits during hashing reject reuse. Worker,
executable, SDK/config/cache-key and all depfile checks remain. Publish receipts
atomically after complete validation and prune obsolete entries on updates.
Receipts assume coherent filesystem change-time semantics and are disposable
local cache evidence, not an adversarial integrity mechanism. First use still
hashes all files. No protocol, builder execution or output-publication behavior
changes; launcher release-binary verification retains its existing policy.

## Warm results

Both lanes disable compiler isolation. The new release frontend is built from
main `5069081` plus this standalone change. Previous frontend: `0195296` with
isolation disabled. Both use identical Dart/worker sources and an existing
workspace/AOT artifact from `json_serializable_10_app`. The prior frontend's
compiler-view experiment is inactive. No dependency transformations are used.

Linux x64, two-CPU quota, 8 GiB memory limit, Dart 3.13.3, Rust/Cargo 1.98.1;
build_runner 2.16.2, Analyzer 14.5.0, dart_style 3.1.13, json_serializable 6.14.1,
build 4.0.11, source_gen 4.2.4. Two workers; SDK/pub/OS/workspace/analyzer/AOT
caches warm. Timing includes the normal Dart launcher and excludes pub get and
native compilation. No concurrent compilation during timing.

Wall seconds, median (min–max), three samples per case/lane:

| Case | Previous full hashing | Digest reuse |
| --- | ---: | ---: |
| no-op | 0.217754 (0.216915–0.218221) | 0.214728 (0.214481–0.218831) |
| one-file | 0.419504 (0.419348–0.420025) | 0.315096 (0.314684–0.315581) |
| broad | 0.465981 (0.465951–0.466361) | 0.367102 (0.366715–0.415404) |

One-file median falls by 104.4 ms (24.9%); broad by 98.9 ms (21.2%). No-op does
not select an AOT worker and shows no useful improvement claim. These are
small, startup-heavy ten-model workloads with comment-only edits and three
observations; percentages do not predict larger or CPU-heavy builders.
Cold performance was not remeasured: first-use hashing/cache publication costs
remain. Historical compiler-isolation cold timings are a separate experiment.

Each lane first performs one unmeasured one-file build to warm validation.
Three rounds alternate old/new order in the same workspace. Each measured
one-file/broad invocation appends comments to one/all inputs so both lanes do
actual dirty work. SDK, sources and caches are shared; outputs are checked
against the stored stock reference after each invocation. All 18 measured
builds match stock. AOT artifact sizes/mtimes remain unchanged throughout,
confirming reuse without compilation or replacement.

## Reproduction and validation

Use a prepared ten-model workspace with published AOT artifacts. With
BUILD_RUNNER_ACCELERATOR_EXPERIMENTAL_COMPILE_ISOLATION absent, alternate the
previous/new release frontend through BUILD_RUNNER_ACCELERATOR_BIN:

```bash
dart --suppress-analytics run build_runner_accelerator build \
  --dart /path/to/dart-sdk/bin/dart --jobs 2
```

Keep the same PUB_CACHE, BUILD_RUNNER_ACCELERATOR_CACHE and
ANALYZER_STATE_LOCATION_OVERRIDE for both lanes; prime one-file once, then
measure three rotating rounds of no-op/one-file/broad, checking stock bytes
and unchanged AOT artifacts. Raw harness/samples/logs stay outside Git:
`/tmp/bra-runtime-default-warm.py`, `/tmp/bra-runtime-default-warm/` and
`/tmp/bra-runtime-default-warm.log`. No raw benchmark JSON is committed.

Standalone Rust: 205 passed, 1 ignored; fmt, Clippy with warnings denied and
release build passed. Regression tests cover cached validation, same-size
writes with restored mtime, file replacement, artifact truncation, and missing/
malformed receipts, including the full AOT validation entrypoint. Broader
SDK/OS and the full behavioral release suite remain validation before merge.
