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
comments are slotted per annotated node (declarations, members, enum
constants, type parameters and formal parameters), so moving a doc
comment between any two of them changes the digest. The walk uses
only the AST surface that is stable across the supported analyzer
window (`AnnotatedNode`, `MethodDeclaration`, `FunctionDeclaration`,
`FunctionBody`); the window's declaration class names differ between
analyzer generations, so the walk avoids them. A self-test on first
use verifies the walk's behavior on a sample library, and a mismatch
makes fingerprints unavailable (the feature stays off) rather than
wrong. The fingerprint of a library is the combination
of its constituent units' fingerprints (the library unit and its
parts, in directive order), so a part's API or doc change is an owner
change, while a part's body-only edit is not.

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
