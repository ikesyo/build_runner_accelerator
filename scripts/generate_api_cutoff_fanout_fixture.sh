#!/usr/bin/env bash
set -euo pipefail

# Generates the ADR 0056 stage 6 fan-out benchmark fixture: one
# shared library and COUNT consumer libraries that each import it,
# plus the whole-graph summary builder from fixtures/api_cutoff_app
# (stage 5). Every consumer action observes the shared library
# through the element model, so a body-only edit to the shared
# library is exactly the case the API cutoff exists for.

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
count=${1:?usage: generate_api_cutoff_fanout_fixture.sh COUNT [DESTINATION]}
destination=${2:-"$repo_root/fixtures/api_cutoff_fanout_app"}
# With GENERATED_PART=1 the shared library gains a generated part
# (a freezed-style .g.dart emitted by a partgen builder in the same
# package), modelling production apps where most handwritten
# libraries have generated parts. The default shape is unchanged.
generated_part=${GENERATED_PART:-0}
if [[ "$generated_part" != 0 && "$generated_part" != 1 ]]; then
  printf 'GENERATED_PART must be 0 or 1: %s\n' "$generated_part" >&2
  exit 2
fi

if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
  printf 'COUNT must be a positive integer: %s\n' "$count" >&2
  exit 2
fi

template_dir="$repo_root/fixtures/api_cutoff_app"
# Portable canonicalization: BSD realpath has no -m flag, and the
# destination usually does not exist yet.
canonicalize() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}
destination_abs=$(canonicalize "$destination")
if [[ "$destination_abs" == "$(canonicalize "$template_dir")" ]]; then
  printf 'DESTINATION must not be the source fixture: %s\n' \
    "$destination" >&2
  exit 2
fi
destination=$destination_abs
if [[ -d "$destination" ]]; then
  listing=$(ls -A "$destination") || {
    printf 'DESTINATION cannot be listed: %s\n' "$destination" >&2
    exit 2
  }
  if [[ -n "$listing" ]]; then
    printf 'DESTINATION is not empty: %s\n' "$destination" >&2
    exit 2
  fi
fi
mkdir -p "$destination/lib"

sed "s/^name: .*/name: api_cutoff_fanout_app/" \
  "$template_dir/pubspec.yaml" >"$destination/pubspec.yaml"
relative=${destination#"$repo_root/fixtures/"}
if [[ "$relative" == "$destination" || "$relative" == */* ]]; then
  # Outside fixtures/, or nested deeper than an immediate child:
  # the template's ../.. would not reach the repository root, so
  # rewrite the path dependency to the absolute root. An immediate
  # child of fixtures/ keeps ../.. as written.
  # Rewrite without sed interpolation: the checkout path can
  # contain characters that are special in a sed replacement.
  # The path is serialized as a quoted YAML scalar.
  python3 - "$destination/pubspec.yaml" "$repo_root" <<'PY'
import sys
path, root = sys.argv[1], sys.argv[2]
escaped = root.replace("\\", "\\\\").replace('"', '\\"')
lines = open(path).read().splitlines(keepends=True)
out = []
for line in lines:
    if line.startswith("    path: ../.."):
        line = '    path: "' + escaped + '"\n'
    out.append(line)
open(path, "w").write("".join(out))
PY
fi

if [[ "$generated_part" == 1 ]]; then
  cat >"$destination/build.yaml" <<'YAML'
targets:
  $default:
    builders:
      api_cutoff_fanout_app:summary:
        generate_for:
          - lib/consumer_*.dart
      api_cutoff_fanout_app:partgen:
        generate_for:
          - lib/shared.dart
builders:
  summary:
    import: "package:api_cutoff_fanout_app/builder.dart"
    builder_factories:
      - summaryBuilder
    build_extensions:
      ".dart":
        - ".summary.txt"
    auto_apply: none
    build_to: source
  partgen:
    import: "package:api_cutoff_fanout_app/builder.dart"
    builder_factories:
      - partgenBuilder
    build_extensions:
      ".dart":
        - ".g.dart"
    auto_apply: none
    build_to: source
    runs_before:
      - api_cutoff_fanout_app:summary
YAML
else
  cat >"$destination/build.yaml" <<'YAML'
targets:
  $default:
    builders:
      api_cutoff_fanout_app:summary:
        generate_for:
          - lib/consumer_*.dart
builders:
  summary:
    import: "package:api_cutoff_fanout_app/builder.dart"
    builder_factories:
      - summaryBuilder
    build_extensions:
      ".dart":
        - ".summary.txt"
    auto_apply: none
    build_to: source
YAML
fi

cat >"$destination/lib/builder.dart" <<'DART'
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';

/// Lines describing one class for the summary output: the class
/// header, one line per method with its documentation comment, and
/// one per constructor with its parameter defaults. The same
/// observation surface as the stage 5 fixture's summary builder.
List<String> describeClass(ClassElement cls, String prefix) {
  final methods = cls.methods.map((method) => method.name).join(',');
  final lines = <String>['$prefix${cls.name} [$methods]'];
  for (final method in cls.methods) {
    final doc = method.documentationComment?.replaceAll('\n', ' ') ?? '-';
    lines.add('$prefix${cls.name}.${method.name} doc=$doc');
  }
  for (final constructor in cls.constructors) {
    final params = constructor.formalParameters
        .map((param) => '${param.name}=${param.defaultValueCode ?? '-'}')
        .join(',');
    lines.add('$prefix${cls.name}.ctor [$params]');
  }
  for (final field in cls.fields) {
    final initializer = field.constantInitializer;
    if (initializer != null) {
      lines.add(
        '$prefix${cls.name}.${field.name} init=${initializer.toSource()}',
      );
    }
  }
  return lines;
}

Builder summaryBuilder(BuilderOptions options) => _SummaryBuilder();

/// A resolver-only whole-graph builder: it observes the input
/// library and its transitive imports exclusively through the
/// element model, which is the observation contract the API
/// cutoff (ADR 0056) relies on.
class _SummaryBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.summary.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final library = await buildStep.resolver.libraryFor(buildStep.inputId);
    final seen = <String>{};
    final lines = <String>[];
    void visit(LibraryElement lib) {
      if (!seen.add(lib.uri.toString())) return;
      for (final cls in lib.classes) {
        lines.addAll(describeClass(cls, '${lib.uri}: '));
      }
      // MIXIN_VISIT
      for (final imported in lib.firstFragment.importedLibraries) {
        visit(imported);
      }
    }

    visit(library);
    lines.sort();
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.summary.txt'),
      lines.join('\n'),
    );
  }
}
DART

if [[ "$generated_part" == 1 ]]; then
  cat >>"$destination/lib/builder.dart" <<'DART'

/// Lines describing one mixin for the summary output, in the
/// same shape as [describeClass]: the header and one line per
/// method with its documentation comment. A mixin declared in a
/// generated part shows up here, which proves the resolver loaded
/// the part when it visited the library.
List<String> describeMixin(MixinElement mixin, String prefix) {
  final methods = mixin.methods.map((method) => method.name).join(',');
  final lines = <String>['$prefix${mixin.name} [$methods]'];
  for (final method in mixin.methods) {
    final doc = method.documentationComment?.replaceAll('\n', ' ') ?? '-';
    lines.add('$prefix${mixin.name}.${method.name} doc=$doc');
  }
  return lines;
}

Builder partgenBuilder(BuilderOptions options) => _PartgenBuilder();

/// A freezed-style part generator for the shared library: it emits
/// a `.g.dart` part declaring the mixin the library applies, so
/// resolving the library always pulls a generated asset into the
/// resolver's unit graph.
class _PartgenBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final source = await buildStep.readAsString(buildStep.inputId);
    if (!source.contains('class Shared')) {
      return;
    }
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.g.dart'),
      "part of 'shared.dart';\n\n"
      '/// Part generated for the shared library.\n'
      'mixin _SharedParts {\n'
      "  String partGreeting() => 'generated part';\n"
      '}\n',
    );
  }
}
DART
fi

python3 - "$destination/lib/builder.dart" "$generated_part" <<'PYEOF'
import sys

path, variant = sys.argv[1], sys.argv[2]
source = open(path).read()
loop = ""
if variant == "1":
    loop = """      for (final mixin in lib.mixins) {
        lines.addAll(describeMixin(mixin, '${lib.uri}: '));
      }
"""
if source.count("      // MIXIN_VISIT\n") != 1:
    raise SystemExit("MIXIN_VISIT placeholder not found exactly once")
open(path, "w").write(source.replace("      // MIXIN_VISIT\n", loop))
PYEOF

if [[ "$generated_part" == 1 ]]; then
  cat >"$destination/lib/shared.dart" <<'DART'
part 'shared.g.dart';

/// Shared library v1.
class Shared with _SharedParts {
  /// Greets with the current revision.
  String greet() => 'shared-v1';

  int compute(int input) => input * 2;
}
DART
else
  cat >"$destination/lib/shared.dart" <<'DART'
/// Shared library v1.
class Shared {
  /// Greets with the current revision.
  String greet() => 'shared-v1';

  int compute(int input) => input * 2;
}
DART
fi

if [[ "$generated_part" == 1 ]]; then
  # A handwritten library only the consumers import: the part
  # producer never observes it, so an edit to it is the shape
  # producer-stability inheritance can waive (the harness primes
  # the part's fingerprint record first).
  cat >"$destination/lib/util.dart" <<'DART'
/// Utility library v1.
class Util {
  /// Greets with the current revision.
  String greet() => 'util-v1';
}
DART
  consumer_extra_import="
import 'util.dart';"
  consumer_describe='Shared().greet() + Util().greet()'
else
  consumer_extra_import=''
  consumer_describe='Shared().greet()'
fi

find "$destination/lib" -maxdepth 1 -type f -name 'consumer_*.dart' -delete
for index in $(seq 1 "$count"); do
  number=$(printf '%03d' "$index")
  cat >"$destination/lib/consumer_${number}.dart" <<DART
import 'shared.dart';${consumer_extra_import}

class Consumer${number} {
  String describe() => ${consumer_describe};
}
DART
done

printf 'generated fan-out fixture: count=%s generated_part=%s destination=%s\n' \
  "$count" "$generated_part" "$destination"
