# ADR 0045: Native Pub workspace builds

- Status: Accepted
- Date: 2026-10-27
- Extends: ADRs 0004, 0035, 0036 and 0040

## Decision

Support `build --workspace` for non-optional normal and post-process builders without shared
parts or trigger-only execution. Reject workspace watch, output policies,
filters, named configurations and `--define`, as well as overlapping nested
source sets and unsupported builder shapes. Outside a Pub workspace the option
uses the ordinary single-package build. The validated two-member fixture is a
bounded compatibility claim, not a claim for every builder configuration.

Use Pub/build_runner workspace paths and package graph roots to identify output
packages and their dev dependencies. Builder auto-application follows stock's
transitive dependency and peer rules. Resolve workspace paths before acquiring
locks, then recheck the complete discovery result under all output-package
locks. Use the same lock files as individual native builds; failure to acquire
any lock releases all acquired locks. Stock processes still require external
serialization as in ADR 0040.

Workspace execution also holds an exclusive coordination lock against prewarm
and cache-key commands, which take a shared coordination lock. Those commands
can still overlap ordinary individual-package builds. After workspace state
exists, individual prewarm and cache-key commands require the same scope reset
as an individual build, so they cannot replace the workspace worker catalog.

Keep the workspace graph and undo journal at the Pub workspace root. Before
workspace execution, reject existing individual native graphs or unfinished
journals in output members. Persist the workspace output-package identities in
an atomically written marker before native actions. Individual builds reject a
workspace marker, and workspace builds reject output-package topology changes.
This deliberately requires a cold state reset to switch scopes or membership;
never remove a marker while leaving a graph that belongs to another scope.
Recovery holds all workspace output locks, and pending undo evidence must be
preserved when the original topology cannot be restored.

The marker can remain after a failed build even when no graph was published;
it establishes the scope for a safe retry. The manifest identity includes Pub's
package graph and package pubspecs, and watch treats their changes as
configuration events. Source outputs and graph state retain the existing
all-success publication and interrupted-commit recovery rules.

## Validation

`scripts/correctness_workspace_json.sh` covers JSON Serializable plus source_gen
combining and post-process cleanup across two members, including no-op, edits,
deletion, rename and failure recovery. Post-process actions use the existing
phase and transactional publication model.

`scripts/correctness_workspace.sh` compares separate stock and native Pub
workspaces with two members. It checks clean/no-op, source edits, deletion,
rename, failure and recovery, AOT with two workers, lock conflicts,
individual-scope rejection and topology change rejection. Rust tests cover lock-group release and marker transitions; Dart
manifest tests check root/member discovery, dev dependencies, selection and
worker catalog generation. This does not validate workspace watch, filtered
builds, shared parts, optional producers or every supported third-party builder.
