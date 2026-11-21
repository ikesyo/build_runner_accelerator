# ADR 0056: API-signature early cutoff for resolver reads

- Status: Accepted
- Date: 2026-11-16

## Context

Invalidation today is content-keyed. When a source file's digest
changes, the dirty check seeds from that asset and expands over both
direct reads and `resolver_reads`: the transitive directive closure an
action's entrypoints resolve against, recorded per action and mirrored
in the frontend's resolver dep graph. A comment-only or
function-body-only edit to one library therefore re-runs every action
that resolves against it, however far downstream.

The v0.19.4 reporter traces quantify this on a real project with
whole-graph (riverpod-style) builders: one such edit re-runs about
2,616 actions and takes about 15 s, against about 37 s for stock.
Body-only and comment-only edits are the most common inner-loop edits,
so this is the largest remaining lever on incremental builds. The
report estimates 3-5 s for the same edit if resolver-mediated
invalidation keyed on the library's API instead of its content. That
estimate is unverified; this ADR treats it as a hypothesis to measure,
not a target to assume.

Two facts shape the design:

- The analyzer already computes an unlinked API signature per unit
  (`computeUnlinkedApiSignature`, exposed as `unit.apiSignature`):
  the declarations, metadata, constant initializers, parameter
  defaults and inference-relevant syntax a dependent can observe
  through the element model, with bodies reduced to their modifiers.
  It deliberately excludes doc comments (its token walk skips comment
  tokens), and the serialized unlinked entry around it also carries
  informative bytes (offsets, line starts) that change on any edit,
  so hashing the entry itself is not a signature.
- Nothing a builder can observe is bounded by the `Resolver`
  interface. Returned elements expose `source.contents`, fragment
  offsets and `element.session`, so a builder can read another
  library's source or positions without calling `astNodeFor` or
  `compilationUnitFor`. Recording wrapper calls can prove content
  use; it cannot prove API-only use.

## Decision

Introduce early cutoff as an opt-in, staged capability. The default
behavior of every builder remains exactly today's content-keyed
invalidation.

### Observation contract and gating

Cutoff applies per builder, only where the builder's configuration
opts in to an API-observation contract: the builder observes other
libraries only through their element-model API, doc comments,
annotations and constant values, never through source text, ASTs of
non-primary libraries, or source positions. `WorkerStepResolver`
still records `astNodeFor`/`compilationUnitFor` calls on non-primary
libraries for opted-in actions; such a call permanently downgrades
that action's recorded reads to content-keyed, as a safety net, not
as the soundness argument. Builders that are not opted in are
unaffected, including their recorded reads.

### Fingerprint

For each source unit, a fingerprint is computed from a parse of the
unit (no linking):

    fingerprint(unit) = BLAKE3(
      analyzer unlinked API signature bytes of the unit,
      digest of the unit's doc comments in declaration order,
      digest of the bodies of executables whose return type is
        omitted, in declaration order)

Doc comments are included because generators such as
riverpod_generator copy them into their output; offsets and other
informative bytes are excluded because the contract forbids
position observation.

The third component closes a verified gap in the analyzer signature
(spike against analyzer 14.6.0, 2026-11-16). The signature changes
for API edits, constant initializers, annotations, parameter
defaults and untyped variable initializers, and is stable across
body-only edits, ordinary comments and offset shifts, as intended.
But it is also stable when the body of an executable with an omitted
return type changes the inferred type (`f() => 1` versus
`f() => 'one'`), including through a private helper in the same
library. The analyzer tolerates this because its unlinked entries
are content-keyed and the owning cycle re-links; a build-level
fingerprint cannot, since a generator can observe the inferred type.
Including the bodies of omitted-type executables (all visibilities:
intra-library inference can chain a private helper's type into a
public one) restores completeness at a small cost to cutoff power:
edits to those bodies stay invalidating.

Implementation notes for the fingerprint walk (stage 1). Doc
comments are slotted per documentable node, including type
parameters and formal parameters, so moving a doc comment between
any two of them changes the digest. The fingerprint must stay
computable across the whole supported analyzer window; where the
resolved analyzer's AST model does not behave as the walk expects,
fingerprints are unavailable rather than approximate. The
fingerprint of a library is the combination
of its constituent units' fingerprints (the library unit and its
parts, in directive order), so a part's API or doc change is an owner
change, while a part's body-only edit is not.

Implementation notes for the recording stage (stage 2). The step
resolver wrapper is unconditional, because the downgrade record must
not depend on profiling being on. Recording itself never fails an
action: a library with no readable asset leaves no record. The
fingerprint store is namespaced by the resolved analyzer as well as
the SDK, since the fingerprint is computed by that analyzer's AST
model; the analyzer is identified by its package root, the same
input the analysis byte store fingerprints. Graph schema 9 carries
the per-action content-read split and the per-unit fingerprints;
schema 10 changes the stored fingerprint to a digest-bound record.
As with earlier schema bumps, an older graph is invalidated rather
than migrated, which later stages see as no evidence; recovery
still decodes an older journal with its own layout.

Implementation notes for the opt-in plumbing (stage 3). The opt-in
surface is the frontend flag `--api-cutoff <builder-key>`,
repeatable; there is no build.yaml surface yet. Keys are normalized
like `--define` spells them and resolved against the configured
builders at plan time: an unknown key is an error, since it could
never apply and accepting it would silently leave the builder
content-keyed. The plan marks opted-in builder instances; the mark
joins the worker pool signature so a changed opt-in set restarts
resident workers, and rides each build request (`api_cutoff`, sent
only when true, lifted into batch `shared` when uniform) so result
assembly knows which actions the safety net applies to. Recording
stays unconditional. No classification changes in this stage.

Fingerprint learning follows the same opt-in. Read recording stays
unconditional because it is cheap, but learning a unit's fingerprint
costs a full-content hash plus a store lookup per unit per worker
per build, which on large resolver closures roughly doubled the dep
walk's cost for builds that never opted in. The worker therefore
learns only while executing an action whose request carries
`api_cutoff`; a build that never opts in records no fingerprints,
and the first opted-in build behaves like a cold start for the
affected builders. Within an opted-in action's walk, repeat visits
to unchanged content are memoized as before. The learning lookup
is keyed by the frontend-supplied snapshot digest
(`asset-digests-v1`) when the walk has one: the persistent cache
answers by digest alone, so the first visit of a build no longer
rehashes the full content of every unit in the closure. Units
without a frontend digest (anything produced or committed during
the build) fall back to hashing the content they were read as. Nested producer
actions restore the caller's setting. Learning happens only in
an opted-in action's own dep walk: a unit an opted-out action
loaded, and a later opted-in action reuses from the cached dep
graph, is not learned until an opted-in walk loads it again, so
in mixed builds the recorded evidence is best-effort rather than
action-order independent. That is safe at this stage because no
build decision consumes the records yet, a missing fingerprint
only ever means "no evidence", and the planner stage binds each
record to the content digest it was learned from and only uses a
fingerprint whose digest matches the current snapshot. The
frontend drops the recorded fingerprints of assets whose
snapshot entry changed before each build, and of the assets a
resolver reset changes before dispatching post-reset actions;
workers clear their learning memos and learned values for the
same assets, so superseded bytes never keep a fingerprint
learned from them. At commit, the frontend also drops the
reported fingerprints of assets the build's transaction wrote,
deleted, or source-edited: a report cannot say which in-build
version of the bytes it describes, and a transaction that
restores an asset's previous bytes would defeat a snapshot
comparison, so those records are removed outright. That is
conservative in one direction: a fingerprint a later phase
learned from the final generated bytes can be dropped when the
output is new or changed. The record is only evidence, so the
cost is a fresh preflight query once the planner stage lands,
never a wrong build decision.

Implementation notes for preflight and classification (stage 4).
The preflight runs after planning and before dirty analysis, and
only when a changed source reaches an opted-in action's recorded
resolver observations; otherwise no worker is started for
classification. Dispatch follows the design above: the pool that
execution will use is started early and stays on as the build pool,
and in watch mode the resident pool answers. The query
(`api_fingerprint_query` under `api-fingerprints-v1`) names the
changed units in the candidates' recorded closures with their
snapshot content digests; the worker reads each unit's current
content itself, verifies it against the digest, and answers with
the unit's fingerprint and direct directive edges computed from
that content, so a watch resident never answers from stale
per-build content state. Effective signatures are folded per
planning pass from the recorded fingerprints and graph, with the
config digest as the environment seed; they are not persisted, so
the graph schema does not change. A library's fingerprint
combination is structural: unit fingerprints fold along the dep
graph's part edges, so no separate assembly step exists. The fold
comparison uses refreshed edges for the queried units only.
Classification waives an action when every root fold matches and
none of its resolver content reads changed: the per-action dirty
predicate ignores its resolver terms, and dirty expansion waives
the resolver channels (recorded resolver reads and the entrypoint
ancestor walk) for changed-source seeds only. Output impacts and
removed outputs are never waived, since a dirty producer's new
output is not covered by source evidence. Boundaries kept
content-keyed in this stage: filtered builds, `--only-check`,
workspace builds (whose execution manages its own dispatch pool,
so a preflight pool could not be reused there), actions with
recorded AST access to a non-primary library (the safety-net
downgrade applies to the whole action, per the gating section
above), and mid-build directive replays, whose edited content
arises during execution and cannot have preflight evidence. The
fold roots are the entrypoints plus the recorded resolver reads
that are not also direct reads: the recorded resolver set keeps
the union for the dirty predicate, but a direct-only read (a
non-Dart config file, say) has no fingerprint and must not block
every waiver by joining the fold. The
unit fingerprint also covers the unit's own language version
override (`// @dart = x.y`), which the element model exposes but
the API signature does not hash; package-level language versions
ride the environment seed. One recording
refinement was needed to make the classification reachable: the
worker's read recording could not tell a builder's direct reads
from the resolver machinery's loads, since both pass through the
same asset RPC. Reads are now attributed at the resolver
machinery's own entry points: the dependency loader's content
read and its readability probe enter their reads under a resolver
scope on the per-action IO state (reads record synchronously at
entry, so the scope only covers entering the read, and nested
actions start unattributed). The shared `contentOf` that builder
steps read through stays unscoped, so a builder's reads remain
direct even with input tracking disabled. Resolver loads land in
a separate per-action set that feeds only `resolver_reads`, so
recorded reads are direct-only, while an asset read both ways
stays in both sets and remains a direct read. Attribution is
scoped to the asynchronous call chain (a zone value carrying
the token of the action that opened the scope), not to an
action-wide flag, so a direct read a builder runs concurrently
with a resolver call keeps its own attribution, and a nested
action triggered from inside a resolver call, whose token
differs, starts unattributed. Two more probe
paths needed the same treatment. The step resolver's entry
points (`libraryFor`, `isLibrary`, `compilationUnitFor`) probe
the target's readability through the build step before
delegating, and that probe preloads the target through the
shared content path: the wrapper runs those calls under the
resolver scope, since the preload records only after an await.
And because the step's input tracker records the probe as an
input regardless, result assembly subtracts assets the IO
attributed to the resolver channel alone from the
tracker-derived reads as well. The preflight query likewise
restores the worker's read caches to their pre-query contents
when it finishes: its reads can observe content newer than the
snapshot (a file edited and then restored mid-build), and the
same worker goes on to execute the build, so no queried content
may stay cached for execution to consume. Fingerprints are
likewise computed under the grammar the resolver itself uses:
the dep walk parses each unit with the feature set of its
package's configured language version (recorded from the
package configuration, with the SDK version as the default),
the effective language version (a unit's override when present,
the package version otherwise) is a fingerprint component, and
the persistent cache keys entries by content digest and package
language version, so an edit that is only valid in a newer
grammar yields no fingerprint for an older package instead of
blessing a build the resolver would reject. The fingerprint also
covers the field initializers of const primary constructors,
whose values the analyzer signature misses because it only
hashes field initializers for traditional const constructors.
Actions recorded
before the split keep the union in their reads and stay
content-keyed until they re-run.

Two further details keep the evidence honest. Recorded fingerprints
are stored bound to the content digest that produced them, and the
fold trusts a recorded fingerprint only when that digest matches
the previous snapshot's bytes for the unit: in watch mode a worker
can learn a fingerprint from content newer than the snapshot a
build commits (an edit that arrives mid-build is deliberately not
recorded in the committed digests, so the next pass notices it),
and such a record must not stand in for the earlier content.
Reports for the same unit that disagree within one build (several
workers observing different bytes after a mid-build edit) are
likewise dropped rather than merged last-writer-wins, and cannot
be resurrected until the next build boundary. And
when execution's pool signature matches the one the preflight
initialized, execution reuses that initialization instead of
resetting every worker a second time; the query is read-only, so
the workers are still in their just-initialized state.

An asset's effective signature folds in its resolver dependencies,
so an API change propagates exactly as far as element-model
observation can reach:

    effective(asset) = H(fingerprint(library of asset),
                         sorted (dep asset id, effective(dep))
                         over the asset's resolver dep edges)

computed over strongly connected components collapsed in dependency
order (import cycles are single components), with the resolution
environment (package configuration identity, declared variables,
SDK and language version) bound into the graph-level seed. Directive
edges are recomputed from current content before signatures are
compared, as the existing content-keyed dep walk already does.

### Preflight and dirty checking

Signatures must exist before dirty expansion; a signature learned
from an action that ran cannot justify skipping that action. When a
build's snapshot contains changed source files and at least one
opted-in action's closure reaches them, a worker preflight parses
the changed units (and any unit whose library fingerprint they feed)
and returns their fingerprints before planning. The fingerprint work
itself is cheap (spike, throttled VM: parse about 0.7 ms and
signature about 0.2 ms per file over a 2,055-file corpus); the real
preflight cost is starting a Dart process, and the design keeps that
off the critical path wherever possible:

- The fingerprint request rides on a worker the build starts anyway.
  A changed file's own actions and direct readers are dirty on
  content rules regardless of any signature, so whenever they exist
  the first worker spawn already happens; it answers the fingerprint
  request before dependent actions are dispatched, and stays on as a
  build worker. In watch mode the resident worker answers, making
  the preflight a bare IPC round trip.
- A dedicated short-lived worker is spawned only when cutoff is the
  build's sole reason to start a process: a changed file consumed
  purely through the resolver, whose API turns out unchanged. Even
  then the comparison is one worker start against the downstream
  re-runs it replaces, and when the API did change the preflight
  worker simply becomes the first build worker.
- The preflight runs only when a changed source file actually
  reaches an opted-in action's closure. Unchanged builds and
  unreachable edits keep today's fast no-op path untouched.

Clean builds never preflight: there are no stored signatures to
compare against, so everything runs as today. Fingerprints are
recorded opportunistically during ordinary builds, computed by
whichever worker parses a unit for its dependency walk and cached
in the persistent store under the unit's content digest, so the
cost is paid once per content rather than once per worker or build.
A graph that predates the capability holds no signatures and is
treated as no evidence: invalidation stays content-keyed until
signatures are recorded, with no forced clean build.

What cannot be removed is the parse itself: whether new content
changed the API is only knowable by looking at its declarations
before planning, and the fingerprint must come from the real Dart
parser (a hand-written declaration scanner in the frontend would
repeat the line-scan failure mode rejected for pubspec parsing in
ADR 0055). A further reduction, an AOT-compiled fingerprint helper
with tens-of-milliseconds startup, is possible but deferred: it adds
a per-platform artifact and an analyzer-version consistency burden
that only measurements from the staged implementation can justify. The frontend compares
effective signatures against the graph's stored values:

- An asset whose content changed but whose effective signature did
  not is *not* a dirty seed for API-keyed resolver reads.
- It remains a seed for its own actions, for direct reads, for
  downgraded (content) resolver reads, and for glob and entrypoint
  invalidation, exactly as today.
- An asset whose effective signature changed is a seed for all of
  the above plus API-keyed resolver reads.

Per-action reads are recorded split by kind (direct, resolver-API,
resolver-content) and per-asset effective signatures are persisted,
both under a graph schema bump and a new protocol capability; a
worker or graph without the capability behaves exactly as today.
Generated assets are excluded from cutoff in this stage: their
signatures would have to be phase-specific, and their producers
re-run on content rules alone. Library augmentations are likewise
out of scope until their directive and summary semantics are pinned
down; a library using augmentations is treated as content-keyed.

Two limitations are known and accepted for this stage; both degrade
to ordinary content-keyed rebuilds, never to stale output. First,
preflight initializes the worker pool for the first candidate's
package, so in a multi-package build whose first executed action
belongs to another package the pool restarts for execution, and a
resident watch pool can restart twice in one pass. Second, a source
file starting with a UTF-8 byte-order mark hashes differently in
the worker (which hashes the decoded content) than in the frontend
snapshot (which hashes the raw bytes), so the digest binding
rejects its fingerprint and any closure containing it stays
content-keyed.

Separately, recorded fingerprints are not yet bound to the Dart
SDK identity. Rebuilding with a different `--dart` SDK without
regenerating the package configuration leaves the config digest
unchanged, so evidence learned under the previous SDK's element
model can still waive an action whose builder observes SDK types
through a unit's API. Regenerating the package configuration (for
example with `dart pub get`) changes the config digest and
invalidates the evidence; binding the evidence to the SDK summary
identity is left for a follow-up.

### Validation

`--only-check` does not validate cutoff: it compares native outputs
against existing files, and a wrongly skipped action cannot reveal
its own stale output. Validation is differential: scripted edit
sequences (comment-only, body-only, doc-comment, constant, API,
part-file and cycle edits) run in isolated stock and native
workspaces, comparing final outputs byte for byte, plus a forced
conservative mode of the native build (cutoff disabled at runtime)
compared against itself with cutoff enabled. A riverpod-style
fixture with a wide resolver fan-out provides the benchmark: clean,
no-op, body-only edit, doc edit and API edit lanes, before any
builder is opted in by default.

## Alternatives considered

- **Hash the analyzer's serialized unlinked or linked summaries.**
  Rejected: the bytes carry informative data (offsets, line starts)
  that changes on body and comment edits, defeating the cutoff, and
  linked bundles are per library cycle with informative data loaded
  separately, so their bytes are not an observation contract.
- **Canonical hash of the resolved element model.** Rejected for
  this stage: making the rendering complete (private elements,
  fragments, evaluated constants, defaults) is a larger and more
  fragile surface than reusing the analyzer's own signature
  computer, and it requires linking before planning.
- **Comment-only cutoff as the whole feature.** Rejected as the
  design, retained as a possible first milestone: doc comments and
  offsets are observable, so even this needs the observation
  contract, and its benefit alone is unmeasured.

## Expected effect

For opted-in whole-graph builders, comment-only and body-only edits
skip nearly all downstream actions; what remains is the snapshot,
the preflight parse of the changed units, the dirty check, the
edited file's own actions and one worker warm-up. On the reporter's
shape of project that is the estimated 3-5 s one-file edit, to be
confirmed or refuted by the fixture benchmark above. API-changing
edits, non-opted-in builders and all other lanes behave exactly as
today, apart from the preflight cost when it runs.

## Stage 6 follow-up (2026-11-22)

The stage 6 fan-out benchmark (`scripts/benchmark_api_cutoff.sh`,
generator `scripts/generate_api_cutoff_fanout_fixture.sh`) generates
one shared library and 200 consumer libraries that import it, with
the stage 5 whole-graph summary builder on every consumer. Measured
on the development VM (shared 1.5 CPU, Dart SDK 3.13.3, jobs 2,
two runs; outputs byte-identical in every lane). Elapsed times
come from the timed pass with metrics disabled, per
docs/development.md; action counts come from a separate counted
pass. Both passes pin BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0
(kernel workers only), so no deferred AOT compilation leaks into
a neighboring lane. Each run's timed pass repeats the sequence
in both variant orders, so every cell below spans four samples
with no fixed run order, and a single timer process brackets
each build so interpreter startup stays out of the measurement.
An earlier metrics-instrumented measurement overstated every
incremental lane for both variants and is superseded by this
table.

| Lane | Cutoff off | Cutoff on | Actions off | Actions on |
| --- | --- | --- | --- | --- |
| Clean (fresh cache) | 41.5 to 43.3 s | 40.3 to 42.7 s | 200 | 200 |
| No-op | 0.10 to 0.13 s | 0.10 to 0.13 s | 0 | 0 |
| Body-only edit | 6.7 to 7.3 s | 0.7 to 1.5 s | 200 | 0 |
| Doc-only edit | 6.5 to 7.3 s | 7.0 to 7.3 s | 200 | 200 |
| API edit | 7.2 to 8.7 s | 7.1 to 8.0 s | 200 | 200 |
| Multi-file edit | 6.5 to 7.3 s | 6.7 to 7.9 s | 200 | 200 |

Readings:

- The body-only lane is the design case: the edit stops at the
  preflight check and no consumer action runs. The residual
  0.7 to 1.5 s is snapshot, fingerprint and fold work plus
  frontend startup.
- The fully cold clean lane shows no measurable cost from enabling
  the cutoff, fingerprint learning included. This closes the
  remeasurement deferred from stage 4: cold builds are dominated
  by manifest generation and worker compilation, not by
  fingerprinting.
- Doc-only and API edits change the fingerprint by design, so both
  variants rerun every consumer. The cutoff variant also pays the
  preflight check, but the end-to-end ranges overlap at this
  graph size, so the comparison does not resolve a preflight
  cost; isolating one would need a diagnostic run, which the
  timed pass deliberately is not.
- The multi-file lane touches every consumer's own input at once,
  so every action is excluded before any fingerprint query and
  the cutoff can waive nothing; the lane shows no measurable
  overhead for broad primary-input edits. It says nothing about
  broad edits to shared dependencies, which still engage
  preflight; the doc and API lanes cover the single-dependency
  case.
- The effective-signature fold stays at planning time (open
  sub-decision 2). With zero actions running, the whole body-only
  step completes in 0.7 to 1.5 s end to end at this graph size;
  the fold's own share is not isolated by this benchmark, but
  the end-to-end step is small enough that the fold is not on a
  critical path worth moving to commit time.
- No builder is opted in by default; that remains a separate
  decision.
