# ADR 0038: Optional producers and post-process demand

- Status: Accepted
- Date: 2026-10-20

## Context

Normal optional producers and post-process actions share a planned generated
input set. A planned input is only a possible output: its producer may never
be demanded, or may successfully emit nothing. Treating post-process input
reads like normal consumer demand executes producers that stock skips.

## Decision

Normal consumers materialize optional primary inputs before deciding whether
to execute. This applies recursively to optional producers with generated
primary inputs. If a producer emits nothing, skip its downstream primary-input
actions and remove their old outputs at the existing all-success commit boundary.
Keep the primary dependency so a later producer change can wake the consumer.

Post-process actions do not create optional demand. They run only after normal
phases, on inputs actually available in the transaction or reusable on disk.
Their runtime input mappings, target filters, generated asset locations, and
phase visibility continue to come from the shared manifest/action model.
Invalidated optional actions that normal consumers did not demand lose their
old outputs before post-process selection. Their committed `undemanded` state
remains eligible for future normal demand. The configuration digest domain is
bumped so older graph evidence cannot authorize reuse under these rules.
No package name controls this behavior.

Builder failures discard staged outputs, deletions, and graph updates. Native-only
execution and explicit rejection outside the supported subset remain unchanged.

## Validation and limits

`fixtures/optional_cleanup_app` compares stock build_runner 2.16.2 with native
execution for undemanded outputs, two optional producer stages, a normal
primary consumer, source/cache producer locations, and cleanup receipts produced
from both generated inputs.
The fixture's cleanup calls `deletePrimaryInput()`. Stock leaves the generated
source files on disk in this configuration; physical output comparisons include
those files as well as receipts and final outputs. This observation does not
establish complete post-build output-reader or full Drift cleanup compatibility.

The comparison covers no-op, edits, omitted producer outputs and stale-output
removal, restoration, demand removal/restoration, normal-output deletion, rename,
source deletion, and atomic recovery from producer and cleanup failures.
The watch probe covers edits, failures, recovery, rename, deletion, and recreation.
The compatibility-lifecycle verification suite retains both probes alongside
the existing optional and post-process checks.
