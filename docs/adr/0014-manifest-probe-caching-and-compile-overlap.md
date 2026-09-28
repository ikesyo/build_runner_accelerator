# ADR 0014: Factory-probe caching and compile overlap in manifest generation

- Status: Accepted
- Date: 2026-09-28

## Context

A cold build serializes three stages that do not depend on each other:

1. `generate_builder_manifest` loads build.yaml inputs, selects builder
   applications, then runs the factory probe — a Dart subprocess that
   instantiates every selected factory to learn runtime mappings and runtime
   builder types (the `part_directive_suffix` flags from ADR 0013).
2. The synchronous worker AOT compile (`dart compile exe` of the generated
   worker entrypoint), which starts only after the manifest is written.
3. The build itself.

On a 4-core reference workspace the probe alone cost ~10s and the compile
~17s, so manifest regeneration added ~27s of serial latency to every cold
build — the largest remaining cold overhead after ADR 0012.

Two facts make most of it redundant:

- The probe's entire input is already hashed: the builder-manifest
  fingerprint covers `package_config` identity, `pubspec.lock`, and every
  package's `build.yaml` — the only inputs to factory instantiation. A
  probe response is therefore a pure function of the fingerprint.
- The probe does not need the worker entrypoint (it probes factories, not
  the worker), and the compile does not need the manifest — only the
  entrypoint script, whose catalog depends on builder selection, not on
  probe results.

## Decision

- The generator writes the worker entrypoint **before** probing, using a
  catalog built straight from selected definitions (`_earlyCatalogEntries`).
  The catalog is a superset of the final one: a builder that later fails
  conversion keeps an unused factory import in the script. On success the
  early and final contents are byte-identical, so a published AOT artifact
  remains valid.
- `probeFactoryMappings` persists the raw probe response under the
  machine-wide cache root from ADR 0012 at
  `<cache>/probe/<builder-manifest-fingerprint>-<impl>.json`, where
  `<impl>` digests the identity of every package in the probed packages'
  transitive dependency closure — a factory's observable behavior is set
  by all the code it can reach, not only its own package. Pub-cache
  packages contribute `name@<versioned dir>` (immutable for a version),
  and mutable locations (path dependencies, SDK or local checkouts)
  contribute a sha256 of their `lib/` sources; the closure is walked via
  each package's pubspec dependencies. If any reachable identity cannot
  be established the cache is skipped entirely, so an edit under a path
  dependency of a probed package can never be masked by a
  fingerprint-identical cache hit. A hit replays
  the response through the same `decodeFactoryProbeResult` validation as a
  live probe, and both read and write require a mapping for every
  probeable request — a partial response (e.g. a factory that threw under
  load) is treated as a miss and is never persisted. Writes are best-effort
  (temp file + rename) and never fail manifest generation.
- The probe request set is narrowed: normal builders are probed only when
  `requiresRuntimeProbe` holds or a declared output could carry a `part`
  file (any output ending in `.dart`/`.part`). A builder whose runtime type
  is unknown simply has no `builderType`, so `part_directive_suffix` stays
  unset and the pre-filter never engages for it — conservative by
  construction.
- `generate_manifest` spawns the generator and polls `try_wait`; the first
  poll that observes the entrypoint file starts
  `early_worker_aot_compile`, which runs the synchronous compile on a
  background thread. The handle is always joined before returning, because
  `prepare_worker_aot` names its temp files after the process id and two
  in-process compiles would clobber each other. The compile only starts
  when the AOT policy would have compiled synchronously anyway and no
  explicit kernel/AOT artifact is configured.

## Consequences

- Cold manifest regeneration on the reference workspace: probe window is
  hidden behind the compile (measured ~27.6s end-to-end vs ~31s serial
  before, and ~19s saved on the 4-core report environment where the probe
  is the long pole). A probe-cache hit removes the probe entirely
  (measured ~7.8s for the regeneration path).
- A failed manifest generation can leave a published shared AOT artifact
  whose worker script contains a builder the manifest rejected. The
  artifact's cache key is content-derived, so it is only ever reused by a
  workspace producing the same entrypoint — which produces the same
  manifest failure — making the artifact unreachable garbage, not a
  correctness hazard.
- `BUILD_RUNNER_ACCELERATOR_CACHE` relocates the probe cache along with the
  other machine-wide stores; correctness fixtures that point it at a
  scratch directory stay hermetic.
- The probe subprocess itself is unchanged; a future move to in-worker
  probing would obsolete the cache without changing the manifest format.
