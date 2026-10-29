# Workspace scheduler fixture

Independent members a and b, member c depending on a, and a non-output path
package helper exercise a two-phase cache-to-source builder chain. Builder
options differ by package and target. Summaries resolve the generated Dart
library and constant value, and c resolves an import of a's generated library
and reads a's generated cache asset. The helper isRoot=false cache
result is compared with stock too.

`scripts/correctness_workspace_scheduler.sh` records action intervals outside
the workspace, uses a builder rendezvous to prove cross-package overlap, checks
jobs=1/2/3, same-package input overlap and immediate dependency release, and compares stock bytes through
clean/no-op/edit/delete/rename/failure/recovery. No timing speedup is claimed.

`scripts/benchmark_workspace_scheduler.py` compares wave and ready-queue native
binaries on controlled skew and balanced inputs, retaining stock byte checks,
exact commands, SDK/cache conditions and repeated clean/no-op/edit samples.

The correctness script also creates fresh ordinary single-package builds with
48 inputs, checks real input overlap, failure admission and rollback, and compares
clean/no-op/edit/broad/delete/rename/recovery bytes with stock. The paired
benchmark accepts `--baseline-bin` and `--candidate-bin` (legacy argument aliases
remain), plus `many`, `single-balanced` and `single-inputs` profiles. Generated
JSON results belong in the chosen results directory, not the repository.
