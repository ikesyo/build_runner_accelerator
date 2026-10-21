# Drift analyzer, modular, and not_shared fixture

This fixture pins `drift` 2.34.4, `drift_dev` 2.34.6, and stock
`build_runner` 2.16.2. The default configuration validates the isolated
`preparing_builder` → `analyzer` → `modular` chain. The
`build.not_shared.yaml` configuration replaces `modular` with the official
`not_shared` builder and retains the complete `driftCleanup` post-process
builder.

In this Drift version, `not_shared` is a non-optional source builder mapping
`.dart` to `.drift.dart`. It follows the two analyzer factories and reads their
generated analysis state. `driftCleanup` resolves these runtime input suffixes:

- `.temp.dart`
- `.drift_prep.json`
- `.drift_module.json`

Stock records those cleanup inputs as logically deleted. It intentionally
leaves their producer files in `.dart_tool/build/generated`, so native retains
the byte-identical files in its artifact tree as well. Later normal builders
can read analyzer intermediates before the post-process phase; the analyzer
probe verifies that visibility boundary. This chain has no `is_optional`
builder, although individual Drift actions can successfully omit declared
outputs. Runtime reads and required inputs carry the dependencies that wake
`not_shared` after Dart or SQL changes.

Run the stock/native lifecycle and native watch checks with one SDK and pub
cache:

```bash
bash scripts/correctness_drift_analyzer.sh
bash scripts/watch_smoke_drift_analyzer.sh
bash scripts/correctness_drift_not_shared.sh
bash scripts/watch_smoke_drift_not_shared.sh
```

The not_shared correctness check compares source and cache bytes for clean and
no-op builds, Dart and SQL edits, input addition/deletion/rename, stale-output
cleanup, and failure recovery. It also checks the generated manifest contract,
stock logical cleanup records, pre-cleanup normal visibility, and native atomic
output/cache/graph retention. The watch check covers generated-output deletion,
SQL changes, builder failure and recovery, rename, deletion, and recreation.
