# ADR 0013: `part` directive pre-filter for part-family builders

- Status: Accepted
- Date: 2026-09-27

## Context

Part-family builders (`SharedPartBuilder`, `PartBuilder`, and the
`CombiningBuilder` that aggregates their intermediate parts) dominate the
action count of large workspaces, yet most of their actions emit nothing:
a `foo.g.dart` part builder can only produce output when `foo.dart`
declares `part 'foo.g.dart';`. External reports of real-world clean builds
showed the majority of actions were zero-output no-ops that still paid full
worker dispatch, source reads, and result assembly.

source_gen already encodes this rule: `PartBuilder` verifies the expected
`part` directive and warns + skips the write when it is absent, and the
combining builder's output only changes when at least one constituent part
file exists. Re-running such an action and recording an empty result is
observationally identical to skipping it — provided the skip is recorded so
stale-output deletion and future dirty checks still run.

## Decision

- The manifest generator detects part-family builders at probe time. A
  builders-entry gains `part_directive_suffix`: the single `.dart` output
  suffix for `PartBuilder`/`CombiningBuilder`, or the combining builder's
  output suffix for `SharedPartBuilder` (whose `.$partId.g.part`
  intermediates only exist to feed the combined file). Builders that probe
  to anything else, or whose suffix cannot be established, get no flag.
- Because runtime factory mappings can change suffixes per application,
  the probe must know each builder's runtime type even for builders that
  need no probe for their mappings. The probe request set is widened to all
  non-post-process builders; canonical mapping overrides stay restricted
  to the previously probe-required set, so probe failure only disables the
  filter for that builder.
- The Rust frontend reads each dirty action's input source (overlay first,
  then the shared asset cache or disk) and scans for a `part` directive
  whose URI equals `<input_stem><part_directive_suffix>`. On any ambiguity
  — unreadable or non-UTF-8 source, escaped or unterminated strings,
  comment over-matches — the action runs normally. Skipped actions record
  a synthetic successful `BuildResult` that reads only the input, so
  transactional commit and stale-output deletion behave exactly as if the
  builder had run and emitted nothing.
- `BUILD_RUNNER_ACCELERATOR_PART_FILTER=0` disables the filter. The number
  of skipped actions is reported as `part_filtered=N` in the metrics block.

## Consequences

- Clean builds skip zero-output actions without running a builder,
  eliminating their worker dispatch and resolver cost. On the reference
  workspace this removed ~87% of eligible actions and shortened the warm
  clean build measurably.
- The filter intentionally over-matches: a `part` directive inside a
  comment or an unmatched URI still lets the action run. The only hard
  skip is a present, parseable `part` list that lacks the expected suffix.
- Semantics stay anchored to source_gen's own rule — outputs remain
  byte-identical to stock build_runner.
