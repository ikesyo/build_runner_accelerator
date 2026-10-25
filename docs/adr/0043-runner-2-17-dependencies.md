# ADR 0043: Runner 2.17 dependency compatibility

- Status: Accepted
- Date: 2026-10-25

## Decision

Extend build_runner to `>=2.15.3 <2.18.0`, build to `>=4.0.9 <5.1.0`,
and build_config to `>=1.3.2 <1.5.0`. Preserve the Dart/Analyzer floors and
ADR 0042's resolver adapter. Certify 2.17.1, whose build 5.0 dependency adds
interfaces without changing the existing worker constructor path. Do not
certify 2.17.0, which depends on retracted build 4.1.0; Pub cannot express a
hole in this continuous range.

Keep shared-library execution behind an explicit manifest rejection until the
native shared-part engine lands. Read its opt-in through a cold compatibility
bridge so build_config 1.3 remains usable. Disabled applications remain valid.
This dependency change and the shared-part engine are separate review units;
the 0.17.0 release waits for both.

## Validation

Pin the same runner in separate stock/native SDK workspaces with identical
lockfiles. Compare initial/no-op, edits, deletion, rename, failure/recovery and
resident watch. Select JIT/AOT explicitly for both implementations. The existing
minimum/current SDK jobs cover 2.17.1 in addition to their downgrade/upgrade
resolutions. Keep the existing native artifacts and tagpr release pipeline.
