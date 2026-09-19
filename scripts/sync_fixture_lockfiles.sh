#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-dart}

is_accelerator_fixture() {
  local pubspec=$1
  awk '
    $0 == "  build_runner_accelerator:" { in_package=1; next }
    in_package && $0 ~ /^  [^[:space:]]/ { exit }
    in_package && $0 ~ /path:[[:space:]]*\.\.\/\.\./ {
      print "yes"
      exit
    }
  ' "$pubspec" | grep -qx yes
}

checked=0
while IFS= read -r lockfile; do
  fixture_dir=${lockfile%/pubspec.lock}
  pubspec="$fixture_dir/pubspec.yaml"
  is_accelerator_fixture "$pubspec" || continue

  checked=$((checked + 1))
  printf 'fixture lockfile sync: %s\n' "${fixture_dir#"$repo_root/"}"
  (
    cd -- "$fixture_dir"
    "$dart_bin" --suppress-analytics pub get
  )
done < <(find "$repo_root/fixtures" -type f -name pubspec.lock -print | sort)

if ((checked == 0)); then
  printf 'fixture lockfile sync: no accelerator fixture lockfiles found\n' >&2
  exit 1
fi

printf 'fixture lockfile sync: updated %d fixture lockfiles\n' "$checked"
