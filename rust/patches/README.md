# Compiler dependency patches

These unified diffs are the source of truth for edits to private compiler
package copies. They are embedded into the Rust frontend with `include_str!`;
applying them requires no Git executable, Dart subprocess, pub override or hook.
The original package cache, application package config and builder asset roots
are never edited.

| Patch | Known upstream versions | Purpose |
| --- | --- | --- |
| `build_runner-resolver-options.patch` | build_runner 2.15.3, 2.16.0, 2.16.1 | Existing dart-lang/build#5197 backport using the worker analysis-options factory |
| `analyzer-compile-isolation.patch` | Analyzer 14.5.0, 14.6.0, 14.7.0 | Separate parsing utilities from resolution imports |
| `build_runner-compile-isolation.patch` | build_runner 2.16.1, 2.16.2 | Redirect parsing imports and reject unsupported nested CLI execution |
| `dart_style-compile-isolation.patch` | dart_style 3.1.13, 3.1.14 | Redirect the parsing import |
| `build_runner_accelerator-compile-isolation.patch` | This checkout | Redirect worker parsing imports |

The resolver backport runs first, under its existing version selection. The
four isolation patches run only with
`BUILD_RUNNER_ACCELERATOR_EXPERIMENTAL_COMPILE_ISOLATION=1`, in the order listed
in `dependency_patches::ISOLATION`. Each package registers patch variants from
oldest to newest: a known version selects its registered variant; an unknown
version tries the last (latest) variant. A variant can cover several known
versions. Failed context matching is an error, with no retry of older variants.
The resolver backport keeps its existing version selection in
`runner_compatibility`; this is not a general package patch manager.

Unknown versions are attempted within normal Pub dependency/SDK constraints.
Successful patch application establishes only an exact source-context match;
it does not establish API or runtime compatibility. Compilation and stock
correctness validation remain necessary.

The applier supports text modifications and new files, with exact, unique
whole-line source context. Hunk line offsets may change; context may not.
Renames, deletes, binary patches, fuzzy matching and partial publication are
unsupported. Contextless insertion is restricted to the beginning of a file
(the resolver import prepend and new parse module). A failure prevents compiler
configuration publication.

To change a patch, compare the original and intended edited sources, update the
committed diff, and check the registered upstream versions. Choose context shared
by those versions; when a new version needs a different patch, append a new
variant and register its known versions, retaining earlier variants for their
versions rather than relaxing matching. Preserve upstream copyright headers and any existing licenses in generated
copies. Cache-lifecycle unit fixtures reconstruct only hunk preimages; they do
not replace validation against actual upstream sources and stock build outputs.

Isolation patch bytes automatically participate in the preparation receipt key;
no manual transformation revision bump is needed. The patch digest is computed
once per frontend process. Existing content hashes still identify generated
copies and compiler artifacts. Unchanged warm preparation reuses the metadata
receipt without applying or parsing patches.

Validate against actual upstream sources and stock outputs with the focused
correctness script (Dart 3.13+ for Analyzer 14.7.0):

```bash
python3 scripts/correctness_compile_isolation.py --analyzer 14.7.0
python3 scripts/correctness_compile_isolation.py --analyzer 14.7.0 --worker-mode aot
```

`scripts/probe_worker_dependencies.py` is the frozen historical measurement
probe; its prototype transforms are not the production patch source of truth.
