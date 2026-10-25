# Shared library parts fixture

Pins build_runner 2.17.1. Two `adds_to_library` builders contribute to each
library; the first also writes an ordinary output, and the second resolves the
first phase's contribution. A later normal builder checks the completed
library throughout the lifecycle, including input-set changes. An optional cache producer verifies
demand and replay behavior, including identical stock/native call histories.

Run from the repository root with one Dart SDK and Pub cache for both sides:

```bash
bash scripts/correctness_shared_parts.sh
bash scripts/correctness_shared_parts.sh --worker-mode aot --jobs 2
DART_BIN=/path/to/dart-3.11.0/bin/dart bash scripts/correctness_shared_parts.sh --resolution downgrade --jobs 2
```

The probe uses separate stock/native workspaces and identical lockfiles. It
compares complete source/output inventories and bytes through initial/no-op,
input edits, empty contributions, automatic directive edits, modified/deleted
output repair, only-check, multiple/nested/non-lib inputs, rename/deletion,
failure and recovery, enhanced-parts imports, and two resident watch edits.
It checks rollback both before and after a directive edit has been staged.
Logs and lockfiles remain in the printed results directory. For local debugging,
`--resume-imports --results PATH` resumes the final checks in an existing run.

Stock 2.17.1 can expose an incomplete library to downstream normal resolvers
when the shared-library input set changes. The default comparison uses an
isolated stock source copy with phase-cache invalidation corrected. It records
the exact correction and hashes in `stock-reference.json`; Pub cache, lockfiles
and the native runtime stay unchanged. The normal consumer stays enabled for
all lifecycle cases. After addition, rename and deletion, the probe also runs
an unmodified, clean stock workspace and compares its complete inventory and
bytes. `--stock-reference raw` reproduces the upstream incremental mismatch.
See [ADR 0044](../../docs/adr/0044-shared-library-parts.md#stock-reference-correction).

The test does not certify filtered/retained-output shared builds, other
platforms, or every runner patch/SDK combination.
