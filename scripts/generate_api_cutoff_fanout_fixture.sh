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

cat >"$destination/lib/shared.dart" <<'DART'
/// Shared library v1.
class Shared {
  /// Greets with the current revision.
  String greet() => 'shared-v1';

  int compute(int input) => input * 2;
}
DART

find "$destination/lib" -maxdepth 1 -type f -name 'consumer_*.dart' -delete
for index in $(seq 1 "$count"); do
  number=$(printf '%03d' "$index")
  cat >"$destination/lib/consumer_${number}.dart" <<DART
import 'shared.dart';

class Consumer${number} {
  String describe() => Shared().greet();
}
DART
done

printf 'generated fan-out fixture: count=%s destination=%s\n' \
  "$count" "$destination"
