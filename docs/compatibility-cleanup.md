# Migration and recovery

This guide covers the changes in the continuing 0.x development line. The
[current CLI/environment reference](launcher-and-release.md) and
[ADR 0030](adr/0030-compatibility-cleanup-and-disposable-state.md) describe the
interfaces, affected producers/consumers, and reasons for this cleanup.

## 0.14.0: stock fallback removal

The accelerator now requires native execution. Unsupported CLI, manifest, state,
or runtime API requests fail explicitly; no stock process is started. Native
binary resolution/download errors also fail, including prewarm. There is no
published macOS Intel artifact; use a compatible preinstalled binary or stock.

| Previous command | Replacement |
| --- | --- |
| `dart run build_runner_accelerator build --mode auto` | `dart run build_runner_accelerator build` |
| `dart run build_runner_accelerator watch --mode rust` | `dart run build_runner_accelerator watch` |
| `dart run build_runner_accelerator build --mode dart` | `dart run build_runner build` |
| Accelerator `clean`, `serve`, or stock-only flags | Run the corresponding `dart run build_runner ...` command directly. |

All old `--mode` values are errors with migration guidance. Both leading and
command-level help/version now describe the accelerator. Stock comparisons
remain the correctness reference; the native supported subset has not widened.

A legacy `stock-output-policy-state` marker is still a refusal boundary: the
native graph cannot import stock's logical digest history. Updating does not
clear the marker or silently resume native execution. Direct stock use no longer
records markers, so reset both build states before returning to native after
stock execution, especially when keeping manually modified outputs.

## Changes to scripts and CI

| Retired behavior | Update |
| --- | --- |
| `aot-prewarm` alias | Use `prewarm`. The alias is rejected; it is not forwarded to stock. |
| `BUILD_RUNNER_ACCELERATOR_PACKED_STORE` | Remove it. All values, including `0`, are ignored; both shared stores are packed-only. Use `BYTE_STORE=0`, `DEP_CACHE=0`, or a fresh `CACHE` directory for diagnosis. These names have the `BUILD_RUNNER_ACCELERATOR_` prefix. |
| Older internal worker artifacts/messages | Update the preinstalled frontend with the package and remove internal `--worker` or artifact overrides. The package regenerates its worker as needed. Required IPC fields and matching versions are checked as specified in [protocol/v1.md](../protocol/v1.md). |

Stock build_runner configuration/builder semantics remain the reference within
the supported native subset. Stock's retired `--delete-conflicting-outputs`/`-d`
flags remain accepted by native build/watch; they are not accelerator aliases.

## Regenerated internal state

Manifests, graphs, worker AOT/kernel artifacts, generator/probe results and
analysis caches are private, disposable state. Identity/format checks regenerate
obsolete or invalid ordinary caches; filesystem I/O errors remain explicit.
Internal schema numbers are defined in source, not a user migration API.
Pending publication undo evidence is the exception: preserve it and complete
[recovery](#interrupted-publication) before resetting or downgrading.

The first build after an update may recompile helpers and refill caches.
`prewarm` prepares compilation/analysis without generating outputs or a graph.
Cache invalidation does not delete user sources or existing generated source
files; a subsequent successful build can replace outputs and remove stale ones.
Native cold builds replace the private artifact tree only after all actions
succeed. Old shared-cache directories can remain unused until manually pruned
while their users are stopped.

## Interrupted publication

After a process stop or publication I/O error, retry the same native build/watch
command. Before graph reuse, it validates the undo journal and restores the
previous output bytes/existence and raw graph, then plans against current inputs
and settings. This includes source/cache outputs and obsolete-output ownership.
A rollback interrupted by another stop/error can be repeated. A graph saved just
before termination is also rolled back if the journal was not yet removed.
`--only-check` preserves its read-only contract: pending recovery fails with
instructions to run a native build without `--only-check` first.
Ordinary builder failures still publish no output changes. Older versions that
interrupted publication without a journal have no undo evidence; their partial
state requires manual reconciliation before reuse or reset.

If automatic recovery refuses an externally changed output, missing/damaged
backup, unreadable/obsolete undo graph, symlink, moved workspace, or I/O error, it reports the reason and preserves
`graph-v3.commit-undo` under `.dart_tool/build_runner_accelerator`. It does not
report a successful build. Stop native and stock processes; copy this directory
and affected files to a safe backup. Fix disk space/permissions and retry. For an
external edit, move the edited file aside before retrying; absent destinations
can be restored from undo copies. For symlinks, preserve the linked file and
remove the link before retrying. Restore a moved workspace to its original path.
If evidence was lost or corrupted, restore intact state/output backups or
manually reconcile the listed outputs before any cold reset. Do not delete just
the graph, discard the undo journal, or run stock over partial publication.
Use a frontend that understands the journal format; older binaries cannot
detect it. Resolve pending recovery before downgrading or switching frontends.
The general reset procedure below applies only after pending recovery is resolved.

This guarantee covers process termination, including forced kill, and recoverable
I/O failures reported by filesystem calls. Files/directories are not fsynced:
power loss, delayed writeback failures after successful calls, and storage
corruption are outside the durability guarantee. External readers can observe intermediate
publication. Native locking excludes competing native writers; serialize direct
stock commands and other output editors yourself. Recovery preserves contents
and existence, not mtimes, modes or empty directories. Journal-owned partial
output/rollback temporary files are removed during recovery. Pre-existing files at reserved temporary paths block publication;
move them aside after backing them up. Recovery does not sweep unknown files. See [ADR 0040](adr/0040-interrupted-commit-recovery.md) for the
publication sequence and I/O costs.

## Safe recovery

1. Stop build/watch/prewarm processes for the workspace and shared cache.
2. Check package and preinstalled frontend versions (`--version`); update the
   frontend to match the package. Remove internal artifact overrides.
3. Retry `build --force-jit` for diagnostics without AOT.
   `BUILD_RUNNER_ACCELERATOR_BYTE_STORE=0` uses memory-only analyzer storage;
   `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0` parses directives without shared
   caching. A fresh `BUILD_RUNNER_ACCELERATOR_CACHE` directory isolates disk state.
4. If `stock-output-policy-state` exists or you have switched to stock since
   the last native build, rename **both** `.dart_tool/build_runner_accelerator`
   and `.dart_tool/build` to backup directories before rebuilding natively.
   Do not remove only the marker: an older native graph cannot reuse stock's
   newer logical digests. This is a cold rebuild and does not preserve keep
   history; copy any manually edited generated outputs you need to retain
   outside the workspace first. Existing generated source files are not deleted
   by the reset, but a successful build can replace them.
5. Otherwise, if a native cache reset is needed, rename only
   `.dart_tool/build_runner_accelerator` to a backup directory and rebuild.
   This preserves sources and generated source files; artifact-tree
   intermediates are rebuilt. Keep backups until outputs have been checked.
6. For immediate stock recovery, use `dart run build_runner build` with the
   required flags. Do not delete sources or generated source outputs to repair
   cache compatibility. Prune obsolete shared directories only while their users
   are stopped.
