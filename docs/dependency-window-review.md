# Dependency window review (2026-10-23)

The supported window is `build_runner >=2.15.3 <2.17.0` and
`analyzer >=13.3.0 <15.0.0`, with Dart `>=3.11.0 <4.0.0`. The runner floor
recovers effective Analyzer 13.3 support. A small, automatic backport handles
[dart-lang/build#5197](https://github.com/dart-lang/build/issues/5197) inside
accelerator compilation. One package, tagpr flow, release workflow and the
existing five Rust artifacts serve the entire window.

## Why a backport is necessary

Independent Pub constraints cannot express “runner 2.16.1 only with Analyzer
below 14.5; newer runner with newer Analyzer.” Runners 2.15.3, 2.16.0 and 2.16.1 accept
`analyzer >=13.3.0 <15.0.0`, but their resolver writes the removed
`AnalysisOptionsImpl.contextFeatures` setter on Analyzer 14.5. Source analysis
of accelerator code misses the transitive compile error. Even though the
accelerator uses its own resolver, imports of other runner internals pull in
the stock resolver implementation.

Upstream 2.16.2 replaces that expression with `AnalysisOptionsBuilder` and
raises its own Analyzer floor to 14.3. The accelerator now backports that
expression in an isolated copy when the application's runner is 2.15.3, 2.16.0 or 2.16.1. The
replacement calls the worker's existing `workerAnalysisOptions` factory, which
also handles Analyzer 13.3's ExperimentStatus cast and feature synchronization.
Other runner versions use their original sources.

This fixes accelerator compilation only. A direct stock invocation of runner
2.16.1 with Analyzer 14.5 remains broken; use stock 2.16.2 as the reference for
that Analyzer version. No Pub cache files, application package configuration,
lockfile, or dependency overrides are changed by the backport.

## Implementation and cache behavior

Native workspace preparation copies runner `lib/`, pubspec and license into
`.dart_tool/build_runner_accelerator/runner-compat/<content-key>/`. It applies
one exact source replacement and rejects an unexpected resolver shape. A
separate `runner-package_config.json` preserves package metadata, rebases all
relative package roots, and redirects only the runner root. The copied files
are checked before use; damaged disposable state fails explicitly and can be
removed and regenerated.

The manifest generator, trigger/factory helpers, source/kernel/AOT worker and
analysis prewarm all use the effective compilation resolution. Builder-visible package roots and dependency bytes continue to use the original
application resolution. The compilation resolution participates
in existing manifest, graph, kernel and AOT cache identities. Changing runner
sources or application resolution invalidates reuse. Preparation removes the
compatibility config when moving to runner 2.16.2 or newer; the original config remains
the watched application input. Publication uses unique staging paths and complete
source directories, so concurrent prewarm cannot expose a partially copied tree.

See [ADR 0042](adr/0042-runner-resolver-compatibility.md) for the boundary.

## Evidence and checks

Initial probes used source commit
`683514e6d05730807f63b9df48730b368d203c6f`, Dart 3.13.3 and Linux x64,
without dependency overrides. Exact runner/Analyzer pairs were resolved with
`dart pub get`; other dependencies used the current solution, including
build 4.0.11 and build_config 1.3.3. These were compile probes, not full
minimum-solution certification.

| build_runner | analyzer | Unadapted worker compilation | Decision |
| --- | --- | --- | --- |
| 2.15.3 | 13.3.0 | Fails | Supported through the runtime adapter and legacy output default |
| 2.16.0 | 13.3.0 | Fails | Supported through the worker runtime adapter |
| 2.16.1 | 13.3.0 | Passes | Supported; backport also uses this Analyzer API |
| 2.16.1 | 14.5.0 | Fails in #5197 | Supported through isolated backport |
| 2.16.2 | 14.3.0 | Passes | Supported unchanged |

The adapted 2.16.1/14.5.0 worker import compiles. Rust tests check isolation,
relative/escaped/Unicode roots, repeated preparation, source edits, transitions
to newer runner versions, unexpected source shapes and cache corruption.

Run the stock/native comparison with an installed Dart SDK and built frontend:

```bash
DART_BIN=/path/to/dart BUILD_RUNNER_ACCELERATOR_BIN=/path/to/frontend \
  python3 scripts/correctness_dependency_window.py
```

It pins runners 2.15.3/2.16.0 with Analyzer 13.3 and 14.5, plus 2.16.1/14.5,
in separate native applications. Stock references use the same runner on
Analyzer 13.3 and fixed runner 2.16.2 on 14.5. The latter reference receives
`--keep-modified-outputs` when comparing the legacy default. The published JSON
Serializable 6.14.1 fixture pins source_helper 1.3.13: source_helper 1.4.0 has
ambiguous extensions with that generator on older Analyzer. No dependency
overrides are used. Checks cover raw output equality, no-op, incremental,
AOT, builder failure without native publication, recovery, watch, rename and deletion,
plus unchanged application configuration and upstream resolver bytes. Legacy
cases additionally cover retained edits across fresh processes, regeneration
following primary-source edits, transactional rejection of retained-output API
access and upgrading to the
modern repair default without deleting accelerator state.

The cases run across existing parallel correctness CI steps. Existing Dart 3.11
`pub downgrade` and Dart 3.13 `pub upgrade` jobs continue to check the minimum
and current solutions; no release jobs or platform matrix entries are added.

## Runtime adapter and earlier versions

The worker owns its minimal BuildState and BuilderFilesystem implementations
instead of inheriting their changing constructors and storage. It retains the
same empty phase plan, original package namespace, committed-content snapshots,
mutable public read copies and single content listener. One explicit interface
bridge accepts the named `contentOf(id: ..., buildStepPlan: ...)` call in 2.16.0
and the positional call in 2.16.1+. Other unknown state/filesystem APIs fail
explicitly. ReaderWriter accepts both `hidden`/`hide` and `inArtifactTree` names;
logical visibility and physical location remain Rust's decision.

Runner 2.15.3 keeps manually modified outputs by default. Native build/watch
select that policy internally from the resolved runner version; raw arguments
and explicit demand-mode restrictions are unchanged. Missing outputs still
trigger regeneration. A changed primary input can replace its retained output.
`--delete-conflicting-outputs` remains a retired no-op in 2.15.3. The selection is recalculated for every process, so upgrading to 2.16+
restores the repair default without sticky graph state.

Existing retained-output safety limits still apply. If a build executes while
an unrelated manual edit must survive, digest/resolver access fails before
publication rather than consuming a stale logical digest or overwriting that
edit through broad resolver invalidation. This is a deliberate bounded support
surface, not complete stock parity for arbitrary retained-output consumers.
Explicit `--keep-modified-outputs` retains its existing demand-mode behavior.
Earlier 2.15 releases are outside the tested window; no further floor reduction
is claimed.

Analyzer below 13.3 would additionally require runner before 2.15.2, which raised
the Analyzer and Dart floors to 13.3 and 3.11. Published Conduit generators
requiring Analyzer 12 still do not resolve; see the
[registry probe](../fixtures/registry_builder_app/README.md).
