# ADR 0038: Optional producers and post-process demand

- Status: Accepted
- Date: 2026-10-20

## Context

The planner includes declared optional outputs so later normal builders can
consume them. These declarations can also match post-process inputs even when
no normal builder demands the producer. A producer can also run successfully
without emitting its declared outputs.

Stock build_runner treats normal consumers as a source of optional demand and
runs post-process actions on the results of normal phases. Execution and graph
reuse must preserve the distinction between a declared output and an available
normal result.

## Decision

Resolve an optional primary input before dispatching its normal consumer. Apply
this rule recursively through optional producer chains. If the producer emits
nothing, skip the consumer and retain its primary dependency so a later producer
change can wake it.

Complete normal demand before selecting post-process inputs. Post-process
actions do not demand optional producers. Invalidate old outputs of dirty
optional actions that normal consumers did not demand, then select cleanup
inputs from the remaining normal results. An undemanded result does not
invalidate cleanup by itself. Newly materialized optional results join cleanup
selection in the same transaction.

Persist an undemanded optional action separately from a successful action that
emitted nothing. Future normal demand can execute the former; the latter remains
reusable until its recorded inputs change. Graph reuse must validate this
execution meaning as part of configuration compatibility.

Invalidate recorded glob consumers when a matching earlier-phase normal
producer is new, dirty, or removed. Include declared candidates that did not
previously emit a file: filesystem scans and recorded content reads cannot
represent a newly available generated glob member. Propagate this invalidation
through normal dependency edges while retaining the undemanded-action rule.
Same/future-phase outputs, post-process outputs, and other-package candidates
do not create glob dependencies. Removed producers invalidate their consumers
even when physical cache bytes remain until commit.
Removal of a same/future-phase producer does not invalidate recorded negative
reads of its hidden outputs. Retain the existing conservative propagation for
dirty producers and resolver closures, which can include generated parts.

Keep output writes, stale-output removal, cleanup deletions, and action state in
one transaction. Publish them only after all required actions succeed.

## Rationale

Demand at a normal primary-input boundary prevents a consumer from running on
an output that its producer omitted. Resolving nested primaries uses the same
rule throughout the dependency chain.

Selecting cleanup inputs after normal demand prevents cleanup from activating
otherwise unused producers or reading their stale outputs. The shared action
model already carries builder kind, optionality, phase, and output location,
so these rules apply uniformly to configured builders.
