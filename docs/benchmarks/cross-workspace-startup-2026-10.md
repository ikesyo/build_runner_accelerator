# Cross-workspace startup review (2026-10-01)

The manifest-window investigation supplied seven commits from `790a980` to
`caf0092`. It found no benefit from full workspace byte-store prefill on the
JSON fixtures, but identified SDK summary generation and workspace-private
manifest kernel keys as avoidable cold-start costs. Full manifest prewarm
remains opt-in; missing-summary auto-prewarm remains gated on at least four
available CPUs. ADRs [0017](../adr/0017-manifest-window-analysis-prewarm.md) and
[0018](../adr/0018-cross-workspace-cold-start-sharing.md) describe the policy.

## Review findings and fixes

- Preserve the mapping from each package name to its resolved directory.
  Sorting only the set of directories collided when two packages' symlink
  targets were swapped. A regression test fails on the supplied implementation
  and passes with the mapping included in the key.
- Preserve workspace package metadata, including language version and package
  URI, while normalizing its unused root location. The supplied implementation
  discarded the whole entry. The language-version regression test also fails
  before the fix and passes after it. Never normalize the accelerator package
  itself, because its libraries are compiled into the generator.
- Decode percent escapes in both relative and absolute package root URIs
  without slicing UTF-8 at arbitrary offsets. Malformed escapes, unsupported
  URIs, malformed package entries and unresolved directories use a conservative
  workspace-local key.
- Resolve relative roots against the config location passed to the VM, even
  when the config file itself is symlinked. Canonicalizing that file first
  incorrectly merged two configurations resolving different dependencies.
- Exclude the originating package-config file from depfile metadata: its
  relevant contents and resolution are already validated by the key. The
  relocated-workspace fixture removes the old config before asserting a hit,
  compares manifests after adjusting only the expected worker path, and
  compares worker source bytes directly.
- Replace exclusive-create/age-based SDK summary locking with persistent OS
  locks. Hold the lock during cache validation as well as cold generation, so
  SDK/dependency changes are serialized too. Process exit releases ownership
  immediately; isolate-local callers share one in-flight future. Lock errors
  and the three-minute wait limit preserve the stock generator fallback.
  Process tests cover cold generation, invalid cached summaries, concurrent
  isolate calls, generator errors, killed holders and bounded waits.
- Exit `--dirs none` after obtaining the summary instead of constructing an
  unused Analyzer driver. Serialize the prewarm guard's Rust tests, and report
  post-summary resolver time without counting summary time twice.
- The reported AOT correctness failure was a script-output bug: the bounded
  verification wrapper captures stdout in its log. The cache-key helper now
  extracts exactly one key from that log, and the correctness script directs
  worker diagnostics to its own log. Empty keys are rejected. The SDK-change
  and worker-source invalidation checks now inspect real keys/compiler output.

## Local comparison

The reproducible comparison uses Dart 3.13.4, pinned Rust 1.98.1, Linux x64,
three available CPUs and `--jobs 3`. The baseline is `main` at `790a980`, built
in a separate checkout, including its original Dart package sources. The
reviewed variant uses the supplied changes plus the fixes above.

Both variants use one resolved dependency set from
`fixtures/json_serializable_10_app`. Each variant primes its own machine-wide
cache in an unmeasured workspace. Measured workspaces are then created afresh,
with missing SDK summaries and workspace build state, but warm machine-wide
worker AOT, probe and analyzer caches. Ordering alternates between variants.
Every clean, no-op, one-file and broad-incremental build asserts generated
bytes against a stock `build_runner` reference. Incremental edits add comments
so the reference bytes remain applicable. Runtime metrics are enabled.

The measurement runs directly through the native frontend and excludes the
Dart launcher, dependency downloads and cold OS page-cache effects. Automatic
SDK-summary prewarm is inactive on this three-CPU machine; these measurements
must not be used to claim its four-or-more-CPU speedup.

```bash
CROSS_WORKSPACE_BASELINE_BIN=/path/to/main/rust/target/release/build_runner_accelerator \
CROSS_WORKSPACE_BASELINE_ROOT=/path/to/main \
CROSS_WORKSPACE_RESULTS="$PWD/bench_cross_workspace" \
CROSS_WORKSPACE_REPEATS=3 JOBS=3 \
BUILD_RUNNER_ACCELERATOR_BIN="$PWD/rust/target/release/build_runner_accelerator" \
  bash scripts/benchmark_cross_workspace_startup.sh
```

The baseline and reviewed binaries must be built with the same pinned Rust
version, and the fixture must be resolved with the same Dart SDK/pub cache.
Choose a fresh result directory for each invocation. Raw logs and JSON
measurements stay local under that directory. The final local result directory
was `bench_cross_workspace_fast_lock`; its machine-cache folders were seeded
from the first trial and then primed again before measurement.

### Results (seconds, medians of three)

| Case | main | reviewed |
| --- | ---: | ---: |
| clean | 27.314 | 3.301 |
| noop | 0.008 | 0.009 |
| one-file | 0.419 | 0.420 |
| broad | 0.473 | 0.573 |

All 24 measured builds produced byte-identical generated outputs. Measured
main clean builds missed the kernel cache; reviewed clean builds hit it.
Neither variant recompiled worker AOT during the measured builds.

An initial trial with a fixed 25 ms SDK lock poll measured warm lock waits
around 26–30 ms and a broad-update median of 0.677 s (main: 0.525 s).
The final implementation retries every 5 ms for the first 100 ms, then backs
off to 25 ms during cold generation. The follow-up reduced observed warm
waits to roughly 6–9 ms. Incremental timings still vary across these small
samples; the table records the observed differences rather than claiming
an incremental speedup.

### Verification

- `cargo test --locked --manifest-path rust/Cargo.toml`: 94 passed.
- `dart --suppress-analytics test`: 78 passed; the six lock process tests
  were rerun after the polling adjustment and passed.
- `dart --suppress-analytics analyze lib/ bin/ tool/ test/`: clean; lock
  analysis and formatting were checked again after the polling adjustment.
- `bash scripts/verify.sh`: passed.
- `VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh`: passed, including
  relocated-config removal, all early-catalog cases, trigger failure recovery
  and the arbitrary-builder output comparisons.
- `bash scripts/correctness_aot_prewarm.sh`: passed after the output/log fixes.
- Both comparison trials checked clean, no-op, one-file and broad outputs
  against stock.
- `git diff --check` and shell syntax checks: clean.

These are local Linux checks, not the full release/platform verification
matrix. The four-or-more-CPU auto-prewarm timing remains the supplied
investigation’s result and was not remeasured here.
