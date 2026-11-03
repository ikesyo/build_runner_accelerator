# Compiler dependency patches

These unified diffs are the source of truth for edits to private compiler
package copies. They are embedded into the Rust frontend with `include_str!`;
applying them requires no Git executable, Dart subprocess, pub override or hook.
The original package cache, application package config and builder asset roots
are never edited.

| Patch | Selected upstream versions | Purpose |
| --- | --- | --- |
| `build_runner-resolver-options.patch` | build_runner 2.15.3, 2.16.0, 2.16.1 | Existing dart-lang/build#5197 backport using the worker analysis-options factory |
| `analyzer-compile-isolation.patch` | Analyzer 14.5.0, 14.6.0 | Separate parsing utilities from resolution imports |
| `build_runner-compile-isolation.patch` | build_runner 2.16.1, 2.16.2 | Redirect parsing imports and reject unsupported nested CLI execution |
| `dart_style-compile-isolation.patch` | dart_style 3.1.13, 3.1.14 | Redirect the parsing import |
| `build_runner_accelerator-compile-isolation.patch` | This checkout | Redirect worker parsing imports |

The resolver backport runs first, under its existing version selection. The
four isolation patches run only with
`BUILD_RUNNER_ACCELERATOR_EXPERIMENTAL_COMPILE_ISOLATION=1`, in the order listed
in `dependency_patches::ISOLATION`. Selection remains in `runner_compatibility`
and `compile_isolation`; this is not a general package patch manager.

The applier supports text modifications and new files, with exact, unique
whole-line source context. Hunk line offsets may change; context may not.
Renames, deletes, binary patches, fuzzy matching and partial publication are
unsupported. Contextless insertion is restricted to the beginning of a file
(the resolver import prepend and new parse module). A failure prevents compiler
configuration publication.

To change a patch, compare the original and intended edited sources, update the
committed diff, and check every selected upstream version. Choose context shared
by those versions; if it differs, use an explicitly selected patch rather than
relaxing matching. Preserve upstream copyright headers and licenses in generated
copies. Cache-lifecycle unit fixtures reconstruct only hunk preimages; they do
not replace validation against actual upstream sources and stock build outputs.

Isolation patch bytes automatically participate in the preparation receipt key;
no manual transformation revision bump is needed. The patch digest is computed
once per frontend process. Existing content hashes still identify generated
copies and compiler artifacts. Unchanged warm preparation reuses the metadata
receipt without applying or parsing patches.

This extraction was checked against the former transforms for all eight
combinations of the selected Analyzer/build_runner/dart_style versions: generated
sources were byte-identical, including the separate 2.16.1 resolver backport.
The refactor changes patch management, not Dart runtime behavior.
