# Worker AOT validation digest reuse

Warm builds hash a roughly 20 MB AOT executable and around a thousand compiler
dependencies whenever selecting a worker. On known local Linux filesystems,
validated digests can be reused when device/inode/mode/size, nanosecond
mtime/ctime and the expected AOT-metadata digest match.

The supported timestamp providers are ext2/3/4, XFS, Btrfs and tmpfs. A kernel
mount-table snapshot identifies eligible devices once per validation. File
checks use the device ID already present in their stamps. This avoids per-file
filesystem queries and remote statfs RPCs. Remote, FUSE, overlay and unknown
filesystems use full hashing; other platforms keep full hashing too. If the
workspace filesystem is ineligible or mount information is unavailable, skip
receipt loading entirely. See [ADR 0005](../adr/0005-performance-and-validation-policy.md).

Both timestamps must be more than two seconds old; whole-second ctime uses
full hashing. Missing/malformed receipts and changed metadata require reads and
hashing. Fresh files are rehashed without sleeping. Worker, executable,
SDK/config/cache-key and all depfile checks remain. Publish receipts atomically
after complete validation and prune obsolete entries on updates. Receipts are
disposable cache evidence, not an adversarial integrity boundary. First use
still hashes all files. Builder execution and publication semantics are unchanged.

## Warm follow-up (2026-11-01)

Linux x64, two-CPU quota, 8 GiB memory limit, Dart 3.13.3, Rust/Cargo 1.98.1;
build_runner 2.16.2, Analyzer 14.5.0, dart_style 3.1.13, json_serializable 6.14.1,
build 4.0.11, source_gen 4.2.4. Two workers and ten JSON models. The workspace
and AOT artifact are on tmpfs; the Pub cache and accelerator Dart sources are
on overlayfs. The current policy therefore reuses artifact evidence but hashes
overlayfs dependency contents. SDK/pub/OS/workspace/analyzer/AOT caches are warm.

Wall seconds, median (min–max), three samples per case/lane, normal Dart launcher:

| Case | Full hashing | Local-filesystem policy |
| --- | ---: | ---: |
| no-op | 0.232209 (0.231184–0.238589) | 0.237893 (0.230928–0.242627) |
| one-file | 0.410895 (0.407225–0.411727) | 0.371031 (0.369721–0.371301) |
| broad | 0.465941 (0.456917–0.467872) | 0.430445 (0.428139–0.435436) |

One-file/broad medians improve by 39.9/35.5 ms (9.7%/7.6%). No-op does not
select a worker and its ranges overlap; no useful improvement is claimed.
Three samples on a small startup-heavy fixture do not predict larger builders.
Cold performance was not remeasured; first-use hashing/publication costs remain.

## Cost of the filesystem restriction

A second comparison invokes the native frontend directly, removing Dart launcher
startup. Three samples per case/lane, median seconds:

| Case | Full hashing | Cache before filesystem gate | Current local-filesystem policy |
| --- | ---: | ---: | ---: |
| one-file | 0.188014 | 0.119414 | 0.143065 |
| broad | 0.255602 | 0.188036 | 0.197692 |

The gate plus the narrower reuse scope adds 23.7/9.7 ms over the earlier cache
on this mixed tmpfs/overlayfs setup. The current policy still saves 44.9/57.9 ms
relative to full hashing. A separate instrumented one-file invocation recorded
0.082 ms for the mount snapshot/root eligibility stage. Device-set lookups use
existing stamps; the main tradeoff here is rereading/hashing overlayfs sources,
not repeatedly querying filesystem types. Results on wholly supported local
filesystems or wholly ineligible workspaces will differ.

## Method and validation

Both lanes share the same prepared workspace, Dart/worker sources and published
AOT artifacts. Full-hash control: saved frontend `0195296` with standard package
resolution; updated frontend: main `5069081` plus this PR. Each lane primes
one-file once, then three rounds rotate order across no-op/one-file/broad.
Comment edits dirty one/all inputs before each measured change case. Pub get
and native compilation are outside timing; no concurrent compilation runs.

Timed child waits block until exit. An external GNU timeout bounds each process
without adding Python timeout-wait polling delays. This corrects the previous
harness's up-to-50-ms exit-detection granularity; earlier percentages are
superseded by the measurements here. All 18 launcher and 27 direct-native
observations matched the stored stock output bytes. AOT sizes/mtimes were
unchanged, consistent with reuse; those fields alone do not exclude replacement
or compilation.

To reproduce, alternate old/new frontends through BUILD_RUNNER_ACCELERATOR_BIN
in a prepared `json_serializable_10_app` workspace with fixed PUB_CACHE,
BUILD_RUNNER_ACCELERATOR_CACHE and ANALYZER_STATE_LOCATION_OVERRIDE:

```bash
dart --suppress-analytics run build_runner_accelerator build \
  --dart /path/to/dart-sdk/bin/dart --jobs 2
```

For native timing, invoke each selected frontend directly with the same build
arguments. Prime once, measure three rounds, check stock bytes and retain AOT
size/mtime observations. Raw harnesses/results remain outside Git at
`/tmp/bra-filesystem-policy-{launcher,native}-blocking.{py,log}` and matching
results directories; `/tmp/bra-filesystem-policy-trace.log` records the separate
instrumented invocation. No raw benchmark JSON is committed.

Rust: 209 passed, 1 ignored; fmt, Clippy with warnings denied and release build
passed. Tests cover filesystem classification, malformed/ambiguous mount data,
remote-device evidence despite a one-hour client clock lead, settled-stamp
boundaries, source/executable edits and missing/malformed receipts. Broader
SDK/OS and full release validation remain before merge.
