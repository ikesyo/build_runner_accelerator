# ADR 0036: Native-only execution

- Status: Accepted
- Date: 2026-10-19
- Release: 0.14.0 (breaking)
- Supersedes stock routing/fallback and auto/rust/dart mode decisions in ADRs
  0001, 0002, 0004, 0006, 0008 and 0028–0035.

## Decision

The accelerator executes only its native frontend with its internal Dart worker.
Remove automatic stock fallback and explicit dart mode. Reject every `--mode`
spelling with migration guidance; users remove auto/rust selections and replace
dart selections with direct `dart run build_runner` commands. Native binary
unavailability, download/integrity failures and unsupported requests fail
explicitly. Prewarm has the same strict availability contract. Leading and
command-level help/version describe the accelerator without resolving a binary.

Keep the supported CLI/manifest/state/runtime API checks. An unsupported runtime
result, including a retained-output API exception caught by a builder, discards
workers and the staged transaction without publishing outputs or graph. Watch
stops on unsupported source/configuration transitions; ordinary builder failure
recovery remains unchanged. Preserve native workspace locking, subprocess
supervision and cancellation cleanup. Remove stock argv transport, stock process
launch/exec, fallback retries, and stock handoff-specific lifecycle machinery.

Keep rejecting existing `stock-output-policy-state` history before native
build/watch setup, with explicit recovery guidance. Do not clear markers or
import logical digests from stock. No new markers are created. Direct stock
execution is outside accelerator supervision and locking; switching back requires
an explicit state reset, especially after keep. The update guide defines backup
and recovery without deleting user sources or generated source files.

## Rationale and scope

Fallback requires lossless argument/status/signal forwarding, late transaction
teardown, watch handoff, and coordination between independent graphs. Those
costs recur across feature changes. Stock is independently invocable, so the
escape hatch does not require maintaining a second execution lane here.

This changes the execution contract, not the supported native subset. Do not
replace removed fallback with partial emulation or broaden accepted inputs.
Dart builders and the dependency on build_runner's private APIs remain.
Other internal cache/compilation fallbacks are separate and unchanged.

## Validation

Retain stock-vs-native output, incremental, failure, deletion, rename and watch
comparisons. Replace stock delegation tests with unsupported-request rejection,
legacy-state recovery and unchanged output/graph assertions. Cover launcher and
direct-native CLI, removed modes, own help/version, generator failures, runtime
API rejection, native writer lock, Ctrl-C and SIGHUP cleanup. Keep release
artifact integrity checks and test native resolution failures as errors.
