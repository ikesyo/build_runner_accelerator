# Worker AOT validation digest reuse

Warm builds hash a roughly 20 MB AOT executable and around a thousand compiler
dependencies whenever selecting a worker. On known local Linux filesystems,
validated digests can be reused when device/inode/mode/size, nanosecond
mtime/ctime and the expected AOT-metadata digest match.

The supported configurations are ext2/3/4, XFS, Btrfs, tmpfs and ordinary
OverlayFS with local backing. A kernel mount-table snapshot identifies eligible
devices once per validation; file checks use their existing device IDs. Direct
network filesystems such as NFS/CIFS, FUSE and unknown types use full hashing.
There are no per-file filesystem queries or remote statfs RPCs. Other platforms
keep full hashing. Ineligible workspaces skip receipt loading.

OverlayFS is eligible under the same local, coherent-metadata assumption as
other supported configurations. Its type alone does not imply a remote clock.
Backing-layer topology is not inspected. Network-backed overlays are outside
this cache contract. [OverlayFS documentation](https://docs.kernel.org/filesystems/overlayfs.html#changes-to-underlying-filesystems)
also excludes out-of-band changes to layers while mounted. See
[ADR 0005](../adr/0005-performance-and-validation-policy.md).

Both timestamps must be more than two seconds old; whole-second ctime uses
full hashing. Missing/malformed receipts and changed metadata require reads and
hashing. Fresh files are rehashed without sleeping. Worker, executable,
SDK/config/cache-key and all depfile checks remain. Publish receipts atomically
after complete validation and prune obsolete entries on updates. Receipts are
disposable cache evidence, not an adversarial integrity boundary. First use
still hashes all files. Builder execution and publication semantics are unchanged.

## Warm comparison (2026-11-01)

Linux x64, two-CPU quota, 8 GiB memory limit, Dart 3.13.3, Rust/Cargo 1.98.1;
build_runner 2.16.2, Analyzer 14.5.0, dart_style 3.1.13, json_serializable 6.14.1,
build 4.0.11, source_gen 4.2.4. Two workers and ten JSON models. The workspace
and AOT artifact are on tmpfs; the Pub cache and accelerator Dart sources are
on overlayfs. SDK/pub/OS/workspace/analyzer/AOT caches are warm.

Wall seconds, median (min–max), three samples per case/lane, normal Dart launcher:

| Case | Full hashing | Overlay excluded | Current: overlay enabled |
| --- | ---: | ---: | ---: |
| no-op | 0.238538 (0.232041–0.250895) | 0.232493 (0.227934–0.244313) | 0.238503 (0.230038–0.242042) |
| one-file | 0.416523 (0.405406–0.440633) | 0.394579 (0.365530–0.395769) | 0.339049 (0.338972–0.340107) |
| broad | 0.510572 (0.467147–0.515994) | 0.423284 (0.420868–0.423458) | 0.400663 (0.380818–0.401493) |

Enabling OverlayFS saves 55.5/22.6 ms for one-file/broad compared with blanket
exclusion. Relative to full hashing, current medians improve by 77.5/109.9 ms
(18.6%/21.5%). No-op ranges overlap; no useful improvement is claimed there.
These three-sample, startup-heavy results are workload-specific. Cold
performance was not remeasured; first-use hashing/publication costs remain.

The earlier blanket exclusion of OverlayFS was too broad. The direct-NFS clock
skew concern does not establish that ordinary local-backed OverlayFS has that
clock problem. It unnecessarily forced dependency rehashing in this container.
The filesystem check remains a mount snapshot plus device-set lookups; an
instrumented invocation of that mechanism measured 0.082 ms before restoring
OverlayFS. Adding OverlayFS eligibility introduces no extra checks or syscalls.

## Method and validation

The three lanes share the same prepared workspace, Dart/worker sources and
existing AOT artifacts. Full-hash control: saved frontend `0195296` with standard
package resolution. Each lane primes one-file once, then three rounds rotate
order across no-op/one-file/broad. Comment edits dirty one/all inputs before
each change case. Pub get/native compilation are outside timing, with no
concurrent compilation. All 27 observations matched stored stock output bytes.
AOT sizes/mtimes were unchanged, consistent with reuse; those fields alone do
not exclude replacement or compilation.

Timed child waits block until exit. An external GNU timeout bounds each process
without Python timeout-wait polling delays. Earlier polling-affected percentages
are superseded by these results.

To reproduce, alternate full-hash, overlay-excluded and current frontends via
BUILD_RUNNER_ACCELERATOR_BIN in a prepared `json_serializable_10_app` workspace,
with fixed PUB_CACHE, BUILD_RUNNER_ACCELERATOR_CACHE and
ANALYZER_STATE_LOCATION_OVERRIDE:

```bash
dart --suppress-analytics run build_runner_accelerator build \
  --dart /path/to/dart-sdk/bin/dart --jobs 2
```

Prime once and measure three rounds, checking stock bytes and AOT size/mtime.
Raw harness/results remain outside Git: `/tmp/bra-overlay-restored-warm.py`,
`/tmp/bra-overlay-restored-warm.log` and `/tmp/bra-overlay-restored-warm/`.
`/tmp/bra-filesystem-policy-trace.log` records the earlier instrumented check.
No raw benchmark JSON is committed.

Rust: 209 passed, 1 ignored; fmt, Clippy with warnings denied and release build
passed. Tests cover OverlayFS eligibility, network/unknown/ambiguous mount
exclusion, malformed mount data, unsupported-device evidence despite a one-hour
client clock lead, settle boundaries, edits and missing/malformed receipts.
Broader SDK/OS and full release validation remain before merge.
