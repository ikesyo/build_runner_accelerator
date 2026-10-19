# Native-only follow-up audit

Baseline: `988e233` (PR #114), after ADR 0036. This audit distinguishes removal
of stock execution from compatibility with stock builder semantics.

## Already completed in the baseline

The removal covers frontend modes, stock argv transport, late retry/exec,
process-group handoff, lock-descriptor inheritance, stock ownership-marker
publication, and the Dart reader of the Rust graph. `select_frontend` already
returns a required native frontend rather than an optional selection. Repeating
these changes would not yield another improvement.

## Priorities

| Priority | Change | Benefit and cost | Status |
| --- | --- | --- | --- |
| 1 | Parse Rust build settings once and borrow them throughout execution | Removes repeated flag expansion, define validation and filter allocation, including during watch cycles; makes invalid arguments fail with their actual cause at entry. Small change with existing parser/CLI coverage. | Implemented in this follow-up |
| 2 | Preserve factory-probe failure diagnostics | `probeFactoryMappings` drains stderr, maps nonzero exit/timeout to an empty mapping and catches other failures the same way. With no automatic stock escape, users need the distinction between an unsupported mapping and a failed probe. Return bounded diagnostics with builder/context and preserve the failure cause without changing the accepted subset or caching failures. | Proposed; generic runtime-mapping rejection also encountered during verification |
| 3 | Separate manifest preparation, supported-subset validation and state preflight within `frontend.rs` | There is now one execution path, so `select_frontend` can become explicit preparation rather than a routing abstraction. Separate functions would expose failure boundaries and reduce nesting. Mechanical extraction first; preserve IO causes and contextual diagnostics. | Proposed |
| 4 | Measure keeping committed graph state in the native watch session | Watch currently loads the persisted graph each cycle. A single native session could retain the last successful state, avoiding decoding and allocation on each event. Potentially useful on large graphs, but requires careful ownership of tentative versus committed state and a memory comparison. | Research before implementation |
| 5 | Consolidate launcher/direct-native CLI contract cases | Dart and Rust still parse the public CLI independently. Shared table-driven rejection/help/config-value cases can prevent drift without adding another serialized settings protocol. Both entry points must continue to work independently. | Proposed |

Priority 1 retains original build arguments only where they are still needed:
official Dart configuration resolution, manifest identity and detached prewarm.
It does not replace Dart's normalized builder settings with Rust's lexical view.
Configuration fingerprint serialization is unchanged. Help/version still tolerate
invalid build arguments; removed modes and conflicting compile flags retain
their rejection behavior. Command-specific policy/filter gates remain in place.

This is a structural refactor, not a measured wall-clock speedup. Settings parsing
is likely small relative to SDK/worker/manifest startup. Do not publish a speedup
claim based on fewer parser calls alone.

For priority 2, return mappings together with a structured failure category
(start failure, timeout, nonzero exit, missing result or malformed response).
Attach builder/factory identity and a bounded stderr tail to the final error;
continue draining pipes and enforcing process cleanup. Do not cache failures or
turn diagnostic recovery into acceptance of an unvalidated mapping. Test child
failure, pipe saturation and timeout separately from valid-but-unsupported
extension mappings. During this audit, a failed cold/warm manifest comparison
had identical worker bytes and configuration fingerprint but differed in optional
`runtime_mapping`/`part_directive_suffix` metadata. Source-probe stages also ran
near the existing 30-second limit. This is evidence to investigate probe result
stability, not proof of a particular failure cause.

For priority 4, first capture graph-load time/bytes and total watch cycle latency
with `BUILD_RUNNER_ACCELERATOR_METRICS=1` and frontend wall tracing, then compare
clean, no-op, one-file and broad incremental runs with metrics disabled for timed
runs. Use the same SDK, cache and worker count; compare output bytes with stock.
Cover failure/retry, delete/rename, configuration reload, filtered demand and
retained output state. Keep disk publication atomic and update resident committed
state only after successful publication. A changed graph lifecycle needs an ADR.
Avoid retaining an extra full graph copy without measuring peak memory.

## Checks that are still necessary

- Ordered `stock_inputs` and `stock_globs` are evidence used by native filtered
  reuse, not a fallback transport. Removing them can silently change invalidation.
- Unsupported filter/builder shapes, cyclic resolver reuse, configuration
  transitions and retained digest/resolver APIs remain outside the validated
  native subset. Converting rejection to success needs independent semantics
  work and stock comparisons; deleting fallback does not establish correctness.
- The legacy stock ownership marker must still reject unsafe old history.
  Native-only execution prevents new markers, not existing installations.
- Workspace locking, worker cancellation, staged outputs and all-success graph
  publication remain necessary with a single frontend.
- Manifest factory/mapping probes and compilation/cache recovery paths serve
  native configuration correctness and startup. They are not stock execution
  fallback and should not be removed based on their names.
- The build_runner dependency and private APIs remain the implementation of
  builders/resolvers. Removing the executable fallback does not remove that
  dependency.

## Validation of priority 1

Use Rust unit tests for settings values that resemble launcher flags, compact
flags, filter identity, worker defaults, unsupported settings and help/version.
Run `scripts/correctness_cli.sh` and `scripts/correctness_settings.sh` for direct
native/launcher rejection, unchanged outputs/graph, settings changes and watch
behavior. Run both quick verification commands required by `AGENTS.md`.

Local results (Dart 3.13.3, Rust 1.98.1):

- `cargo test --locked --manifest-path rust/Cargo.toml`: 149 passed, one ignored.
- Rust format and all-target/all-feature Clippy with `-D warnings`: passed.
- Dart analysis and `scripts/correctness_cli.sh`: passed, including watch,
  Ctrl-C and SIGHUP cleanup.
- Smoke comparison: byte-identical generated output and native no-op passed.
- The isolated settings comparison passed all 31 configuration cases. The
  remaining file-change/error/watch portions were interrupted to move broad
  validation to draft-PR CI; this is not a full settings-suite pass.
- `scripts/verify.sh` stopped at the manifest snapshot cold/warm comparison
  described above. It is not a passing quick verification. The second quick
  wrapper and full release/benchmark suites were deferred to CI at the user's
  request. No wall-clock performance claim is made.
