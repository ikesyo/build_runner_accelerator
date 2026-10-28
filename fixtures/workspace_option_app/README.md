# Pub workspace fixture

This fixture pins build_runner 2.16.2 and contains two output members using a
normal source builder supplied by a third workspace package. The builder emits
`.gen` files from `.txt` inputs and fails on `FAIL` to exercise all-success
publication across members.

Run `bash scripts/correctness_workspace.sh` for isolated stock/native comparisons
of initial, no-op, edit, delete, rename and recovery behavior. The script also
checks AOT with two workers, lock conflicts, and rejection of individual-build
and workspace-topology transitions. It
uses the same Dart SDK and pub cache for both implementations. Workspace watch,
filters, output policies, named configs, optional/post-process builders and
shared parts are outside this fixture's supported workspace subset.
