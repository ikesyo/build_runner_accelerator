# 0031: Stock setting abbreviations and config asset paths

Status: Accepted

## Context

ADR 0030 initially restricted native settings to separate short option values
and single-filename config names. Stock 2.16.2 also supports attached values,
grouped boolean abbreviations and normalized config AssetIds. These spellings
must resolve settings instead of selecting stock solely for syntax.

## Decision

Support `-cNAME` and groups of native boolean abbreviations (`r`, `d`), retaining
the original arguments through every fallback/prewarm boundary. Follow args:
an attached value consumes the whole suffix only when its option comes first;
non-flag abbreviations later in a group are invalid. `-c=NAME` includes `=` in
the value. Values of separate options must never be expanded as flags. Grouping
does not extend the build/watch-only acceptance of the retired `d` flag.

Construct `build.<config>.yaml` before normalization, replace backslashes with
forward slashes, and normalize POSIX segments inside the package like AssetId.
Reject paths escaping the package, after choosing the last config value.
Use the resulting path for launcher/native preflight, loading, and manifest
identity. Include full relative filenames in the fingerprint and invalidate
previous parser/cache identities. Config is still a name, not a file-path option.

In stock 2.16.2 watch, the configuration-reload predicate compares the raw name,
not the normalized AssetId. Keep the resolved native plan when such a selected
file changes without a recognized configuration event; subsequent source edits
also use that plan. A recognized configuration event re-resolves the selected
file. Match stock's deepest-package attribution as well: a selected root config
inside a dependency is not a root config event. Canonical selected root configs
take precedence over generic native artifact/generated-output event filters.
Canonical nested names reload normally; separate build/prewarm invocations
always resolve current settings. Preserve ADR 0030's topology fallback/error.

## Validation

Compare accepted short spellings and resolved paths with stock CLI/BuildOptions
and AssetId. Compare actual outputs, deletion/retention, restored/no-op builds,
invalid spellings and missing/escaping configs across frontend/fallback modes.
Include nested/normalized configs in JIT/AOT/prewarm and resident watch fixtures,
including the raw-versus-normalized reload distinction. This replaces only
ADR 0030's spelling/path restriction, keeping the other CLI and watch boundaries.
