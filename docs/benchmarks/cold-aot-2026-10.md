# Fully cold AOT startup after isolating official trigger parsing

Measured on 2026-10-02 with the normal project-facing Dart launcher. The
worker remains AOT; this experiment does not change its execution policy.
See [ADR 0023](../adr/0023-manifest-trigger-parser-isolation.md).

## Environment and method

- Managed Linux x64 executor, 3 available CPUs (`nproc`).
- Dart 3.13.3, Rust 1.98.1, optimized release frontend.
- `build_runner` 2.16.1, `json_serializable` 6.14.1, `json_annotation` 4.12.0.
- Fixture: `json_serializable_10_app`, ten independent inputs; native jobs=1.
- Baseline Dart sources: `ab079eced1ad22d18d747290b167e65c368cb2d8`.
- Candidate: `2989dd283c3aaa1d14852a7d501cba89ed078f8f`, using the identical
  Rust binary as the baseline.
- Three independent repeats, alternating stock/baseline/candidate order with
  candidate/baseline/stock. No concurrent builds ran during measurement.
- SDK, pub packages, and OS page cache were warm. Every lane/repeat used a
  fresh workspace and empty accelerator and analyzer caches. Offline dependency
  resolution ran before timing; no manual prewarm ran. Native artifact download
  and dependency downloads are excluded.
- Accelerator builds used the existing synchronous AOT policy (`1`) and strict
  Rust mode. Runtime diagnostics/metrics were disabled in timed runs.
- Stock: `dart --suppress-analytics run build_runner build`.
  Accelerator: `dart --suppress-analytics run build_runner_accelerator build
  --mode rust --dart <same-sdk-dart> --jobs 1`, with
  `BUILD_RUNNER_ACCELERATOR_BIN` selecting the prebuilt frontend.
- After each cold build, the same workspace measured no-op, a comment appended
  to one input, and comments appended to all inputs.

## Results

Wall time in seconds, median of three repeats; minimum–maximum in parentheses.

| Case | Stock | Baseline AOT | Candidate AOT |
| --- | ---: | ---: | ---: |
| Fully cold | 37.272 (36.366–37.772) | 34.575 (34.412–35.069) | 31.644 (31.598–32.022) |
| No-op | 0.818 (0.818–0.874) | 0.165 (0.164–0.215) | 0.165 (0.164–0.218) |
| One-file | 0.869 (0.869–0.873) | 0.415 (0.415–0.416) | 0.419 (0.415–0.422) |
| Broad | 0.869 (0.867–0.917) | 0.419 (0.415–0.470) | 0.418 (0.416–0.466) |

Candidate cold time is **15.1% lower than stock (1.18x speedup)** and **8.5%
lower than the baseline**. Its slowest cold sample is still 4.344 seconds faster
than stock's fastest sample. Warm measurements show no material change; the
one-file difference is four milliseconds and the ranges overlap.

Median child user+system CPU time for cold builds:

| Stock | Baseline | Candidate |
| ---: | ---: | ---: |
| 45.560 s | 50.714 s | 39.491 s |

The candidate removes 22.1% of baseline child CPU work. The manifest kernel
shrinks from 28,243,208 to 1,943,328 bytes and its dependency count drops from
800 to 153; Analyzer source dependencies drop from 384 to zero. Worker AOT
compilation remains the dominant cold cost, so the CPU reduction is larger than
the wall-time reduction.

## Correctness and artifacts

All 36 measured invocations succeeded and produced source outputs byte-identical
to stock. Both native lanes produced identical normalized manifests, including
the official trigger digest, and identical generated worker entrypoints.
Only workspace-specific fingerprint and worker-path fields were excluded from
manifest comparison. The harness checks AOT artifacts and rejects kernel/script
fallback. No-op builds skip worker execution.

Raw metadata, commands, JSONL measurements, and per-case logs are retained locally
under `.dart_tool/cold-aot-final-json10/`. Source and binary identities:

- Baseline Dart sources SHA-256: `b708ca862f1634dae243321bbf112ac9a6f8766daa7875b3b211974097951051`
- Candidate Dart sources SHA-256: `e4fee46e2577c2cdd66d5b8fcaf331f67b8600e58486b87775234c25db411e14`
- Native binary SHA-256: `de9555e1084d5106f84c99ead8361c416757e1dfffdce9a107ef92a2d935df4d`

Reproduction from an extracted baseline source tree:

```bash
python3 scripts/benchmark_cold_aot.py \
  --baseline-root /tmp/cold-baseline-source \
  --native "$PWD/rust/target/release/build_runner_accelerator" \
  --dart "$PWD/.toolchains/dart/dart-sdk/bin/dart" \
  --pub-cache "$PWD/.pub-cache" \
  --results "$PWD/.dart_tool/cold-aot-final-json10" \
  --repeats 3 --jobs 1
```

The result directory must be new. The baseline needs `pubspec.yaml`, lockfile,
`lib`, `bin`, and `tool` from the baseline revision. Both native lanes share one
binary because this change only modifies Dart code.

Validation passed:

- Rust: 97 tests; release build.
- Dart: 109 tests. Five local HTTP downloader tests required socket access and
  passed on rerun; the other 104 passed in the restricted network sandbox.
- Static analysis of `lib`, `bin`, `test`, and `tool`; formatting and diff checks.
- `bash scripts/verify.sh` and `VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh`:
  JSON smoke, manifest cache and relocation, early AOT/helper fallback and source
  mismatch, trigger configuration and recovery, arbitrary builder cases.
- `VERIFY_LEVEL=full VERIFY_FULL_SUITES=current-codegen bash scripts/verify.sh`:
  Freezed and Riverpod correctness and watch checks. Missing pinned packages were
  downloaded first; verification then used an offline Dart CLI wrapper.

These speed results cover this fixture and executor. Freezed/Riverpod correctness
is covered, but their cold performance, other SDKs/platforms, and the remaining
full-suite union were not remeasured. They remain broader release/merge checks.
