# ADR 0040: Undo journal for interrupted output publication

- Status: Accepted
- Date: 2026-10-23
- Extends: ADRs 0002, 0034 and 0037

## Decision

Retain the all-builders-success publication boundary and workspace OS writer
lock. Before the first output mutation, save undo copies of every affected
existing output and the previous raw graph, then atomically publish a versioned
journal at `graph-v3.commit-undo/journal.json` next to the graph. Record absent
outputs, absolute destination paths, old content digests and intended new
content digests. Reserve dedicated sibling temporary paths, requiring them to
be absent before journal publication; create these exclusively and remove only
these owned partial writes during recovery. Bind the journal to its original
graph path. This is private state, not a migration or interchange format.

The mutation set comes from the completed transaction: source/cache output
writes, location transitions, deletions, obsolete action outputs (including
dynamic post-process outputs), and all files in a cold-build artifact-tree
cleanup. Do not replace the old graph with an empty graph: ownership, pending
obsolete-output deletion and retained logical digests must survive recovery.
Filtered builds journal only their actual mutations; kept, undemanded outputs
remain untouched. Only-check publishes no journal and refuses pending recovery
without changing files; an ordinary build must recover first. Metadata-only,
no-op and outputless-action saves need no undo journal because they do not
mutate output files; the existing atomic graph replacement suffices.

Deletion ignores only `NotFound`; metadata errors must not masquerade as absence.
Publish output deletions and per-file atomic writes in the existing order,
then scan and atomically save the graph. Unlink the journal only after graph
save succeeds; this unlink is the completion point. Unreferenced undo files
are best-effort cleanup and may be overwritten by later preparation. A process
stopped during preparation has not changed outputs. A process stopped after
the completion point has a complete graph and output set.

Before decoding or reusing any persisted/resident graph, build and watch check
for unfinished publication and roll back to the old graph and output bytes.
First validate every backup and destination; existing destination content must
match either the before or intended after digest, or be absent. Reject non-file destinations, symbolic
links, damaged/missing backups, incompatible/relocated journals and unexpected
external edits. The saved graph must pass strict current-format/schema decoding;
ordinary obsolete/corrupt-graph invalidation must never discard recovery
ownership. Preserve all recovery evidence and report the affected path
and safe next steps. The journal is trusted private metadata, not protection
against an adversary editing it or digest collisions.

Restore each output atomically, then the old graph, then unlink the journal.
The journal remains authoritative throughout rollback. A failed or killed
rollback can repeat the same validation and restoration. Discard tentative
resident watch state on failure or pending recovery. Recovery precedes event
classification as well as execution, so an old resident graph cannot conceal
partial publication. First-attempt watch failures also recover before waiting
for the next event.

## Guarantees and limits

This handles process termination (including forced kill) and recoverable
filesystem I/O errors reported by preparation/publication/recovery calls, with
normal OS/filesystem write and rename semantics. Delayed writeback failures
after successful calls are outside this durability guarantee.
There is no fsync of files/directories and **no power-loss or storage-corruption
durability guarantee**. Readers outside the native lock can observe intermediate
files. The output tree and graph are not a simultaneously atomic snapshot.
Serialize stock commands and other output writers with native build/watch;
they do not participate in its lock. Stop watch before manually repairing state.
Older unjournaled interruptions cannot be detected or repaired retroactively.
A permanently unwritable filesystem or lost undo evidence requires manual
reconciliation; do not silently discard ownership evidence or report success.
Interrupted output/rollback writes can leave partial sibling temporary files.
Their paths are reserved by the journal and removed before rollback, preventing
them from leaking into source globs. Pre-existing files at those paths block
publication without alteration. Unknown siblings are never swept.
Recovery restores contents and existence, not timestamps, permissions or empty
directory layout. A filesystem that cannot atomically replace a file is outside
this guarantee.

## Cost and alternatives

A changed build adds reads and undo writes proportional to affected old output
bytes plus the old graph, content hashing of new output bytes, and a small
journal write/unlink. Cold cache cleanup additionally enumerates and backs up
the private cache tree. Backups are copied one at a time. Recovery validates
all backups before changing any file, then rereads and rechecks each output
backup for restoration. This adds a second backup read only during recovery,
while keeping content buffers proportional to the largest output plus the old graph,
rather than the sum of all affected outputs.
Unchanged no-op/only-check builds copy no outputs or graph for undo. Startup
adds an absent-journal check; resident watch checks at event/build boundaries.
Opt-in wall traces expose `commit_undo_prepare` and `commit_undo_recovery`.
These costs buy recovery without rerunning builders against a mixed tree.

A start marker followed by graph invalidation loses obsolete-output ownership
and keep history. Roll-forward would require persisting the complete new graph
and outputs, including post-commit scan evidence, and handling intervening source
edits. Undo copies reuse the existing successful-build path and safely restore
its exact prior ownership. Per-action publication remains rejected because
later builder failures must protect the last successful build.
