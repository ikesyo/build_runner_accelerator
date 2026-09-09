#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
count=${1:?usage: generate_json_serializable_fixture.sh COUNT [DESTINATION]}
destination=${2:-"$repo_root/fixtures/json_serializable_${count}_app"}

if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
  printf 'COUNT must be a positive integer: %s\n' "$count" >&2
  exit 2
fi
case "$destination" in
  "$repo_root/fixtures/json_serializable_"*_app) ;;
  *)
    printf 'refusing to generate outside a scale fixture path: %s\n' "$destination" >&2
    exit 2
    ;;
esac

template_dir="$repo_root/fixtures/json_serializable_app"
package_name="json_serializable_${count}_app"
mkdir -p "$destination/lib"
cp "$template_dir/pubspec.yaml" "$destination/pubspec.yaml"
cp "$template_dir/build.yaml" "$destination/build.yaml"
sed -i "s/name: json_serializable_app/name: $package_name/" "$destination/pubspec.yaml"

find "$destination/lib" -maxdepth 1 -type f -name 'model_*.dart' -delete

for index in $(seq 1 "$count"); do
  number=$(printf '%03d' "$index")
  source="$destination/lib/model_${number}.dart"
  printf '%s\n' \
    "import 'package:json_annotation/json_annotation.dart';" \
    "" \
    "part 'model_${number}.g.dart';" \
    "" \
    '// benchmark marker: 0' \
    '@JsonSerializable()' \
    "class Model${number} {" \
    "  const Model${number}({required this.id, required this.value});" \
    '' \
    '  final int id;' \
    '  final String value;' \
    '' \
    "  factory Model${number}.fromJson(Map<String, dynamic> json) =>" \
    "      _"'$'"Model${number}FromJson(json);" \
    '' \
    '  Map<String, dynamic> toJson() =>' \
    "      _"'$'"Model${number}ToJson(this);" \
    '}' > "$source"
done

printf 'generated %s Dart files in %s\n' "$count" "$destination"
