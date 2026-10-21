# Published web compiler probe

This single-package probe pins the unmodified published
`build_web_compilers` 4.8.12 and stock `build_runner` 2.16.2. It uses Dart
3.13.3, `compiler: dart2js`, `dart2js_args: [-O1]`, dev configuration, and
`generate_for: [web/**.dart]`. No dependency overrides are used. Production
constraints are unchanged. DDC, hot reload, dart2wasm, deferred loading,
release configuration and multi-package/workspace compatibility are separate
research scopes.

## Published contract

The pub.dev package metadata requires SDK `>=3.13.0 <3.15.0-z`, Analyzer
`>=13.3.0 <15.0.0`, build `>=2.0.0 <5.0.0`, and build_runner `^2.0.0`.
The lockfile records the actual solution. The downloaded archive SHA-256 is
`0c41652721f5ae373028e13e140806867b7cb73ee00df18d48cf6b5386cbe090`.
Sources: <https://pub.dev/api/packages/build_web_compilers/versions/4.8.12>
and <https://pub.dev/api/archives/build_web_compilers-4.8.12.tar.gz>.

Read `build.yaml`, `lib/builders.dart`, `lib/src/web_entrypoint_builder.dart`,
`lib/src/dart2js_bootstrap.dart`, `lib/src/archive_extractor.dart`, and
`lib/src/build_modules/` from that archive to reproduce the investigation.
The former build_modules implementation is bundled within this package.

- `module_library` parses source directives without requesting a Resolver.
- The optional dart2js factories produce raw/clean meta modules from `$lib$`
  and per-library `.dart2js.module` assets. Meta-module collection uses
  `findAssets('**.module.library')`; reads demand optional producers.
- The entrypoint builder parses the input to detect `main`, reads module
  metadata and transitive Dart sources, and uses a Resource-managed scratch
  space. It invokes SDK `bin/dart compile js` with the multi-root filesystem,
  a generated package config, and SDK `lib/libraries.json`.
- Entry JS and map are explicit cache outputs. Other compiler outputs are
  archived; archive entries include filesystem mode and mtime. The public
  post-process extractor emits dynamic cache outputs and deletes its input.
  `module_cleanup` logically removes module metadata. Physical stock cache
  retention must be distinguished from logical readability.
- DDC-related factories remain publicly applied but optional and must not be
  assumed to execute merely because they are present. The entrypoint marker
  is a no-op with hot reload disabled. SDK JS compilation/copy is for DDC.

The selected mode avoids DDC's kernel worker, SDK JS and frontend-server
requirements while exercising real compilation and the optional module chain.
This choice does not imply support for those other modes.

## Validation

Investigation is in progress. A successful solver run is not a compatibility
claim. Record raw file-set and byte comparisons separately from any diagnostic
normalization, including timestamps or scratch paths in archives/maps.
