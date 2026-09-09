# ADR 0005: Performance and validation policy

- Status: Accepted
- Date: 2026-09-07

## Context

The dominant costs vary by workspace: filesystem discovery, graph work, Dart
worker startup, Analyzer initialization, asset RPC, and builder execution can
each dominate a different case. Historical single-run measurements are useful
for investigation but are not stable release guarantees.

Parallel workers can improve broad incremental builds while worsening no-op and
small changes through extra startup and repeated reads. Optimizations that
change scheduling or cache lifetime can also change correctness.

## Decision

Use the following policy:

- Keep the default worker count at one until a reproducible benchmark justifies
  a different default. --jobs N is an explicit opt-in for experiments and
  suitable large workspaces.
- Start only the workers needed by the current ready-action set and batch
  independent requests where it preserves phase and resource semantics.
- Keep runtime and worker-stage metrics opt-in and stderr-only through
  BUILD_RUNNER_ACCELERATOR_METRICS=1.
- Scope read, resolver, glob, and SDK-summary caches to a workspace/build or
  worker lifetime whose invalidation rules are explicit. Do not share cache
  state across incompatible SDK, package, or workspace identities.
- Treat worker AOT/kernel caches as derived artifacts. The launcher defaults to
  the workspace-local AOT worker because dirty-build startup is a primary
  release performance target. A cache miss must preserve correctness and
  provide a usable kernel/script-worker path; `BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0`
  remains an explicit opt-out. The launcher also accepts stock-compatible
  `--force-aot` and `--force-jit` flags, with explicit flags taking precedence
  over the environment variable.
- For performance changes, compare clean, no-op, one-file, and broad
  incremental cases with the same SDK, dependency lock, cache state, command,
  worker count, and byte-identical output check.
- Keep correctness gates deterministic and serial when parallel execution could
  share process or filesystem state.

## Consequences

The project can report where time is spent without making old benchmark values
part of the public API. Performance claims remain reproducible and subordinate
to stock-output and failure-recovery checks. Some optimizations are deferred
until their measurement and invalidation costs are understood.

The native frontend can be faster on broad or repeated work while showing
little benefit on a small no-op dominated by Dart/Analyzer startup. The
launcher adds startup work but does not enter the action scheduler; direct
binary selection remains available when measuring frontend performance itself.

## Alternatives considered

- Default to the highest measured worker count: rejected because workload and
  machine characteristics vary.
- Publish historical benchmark numbers as guarantees: rejected because they
  are environment-dependent.
- Make every diagnostic metric part of the protocol: rejected because it
  increases compatibility surface and can perturb normal execution.
