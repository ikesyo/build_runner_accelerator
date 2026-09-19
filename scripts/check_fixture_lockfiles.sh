#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

root_version=$(
  awk '
    $1 == "version:" {
      gsub(/^"/, "", $2)
      gsub(/"$/, "", $2)
      print $2
      exit
    }
  ' "$repo_root/pubspec.yaml"
)

if [[ -z "$root_version" ]]; then
  printf 'fixture lockfile check: root package version is missing\n' >&2
  exit 1
fi

checked=0
status=0
while IFS= read -r lockfile; do
  fixture_dir=${lockfile%/pubspec.lock}
  pubspec="$fixture_dir/pubspec.yaml"

  # Only inspect fixtures that depend on this repository through a path
  # dependency. Other lockfiles under fixtures may belong to standalone probes.
  if ! awk '
    $0 == "  build_runner_accelerator:" { in_package=1; next }
    in_package && $0 ~ /^  [^[:space:]]/ { exit }
    in_package && $0 ~ /path:[[:space:]]*\.\.\/\.\./ {
      print "yes"
      exit
    }
  ' "$pubspec" | grep -qx yes; then
    continue
  fi

  checked=$((checked + 1))
  lock_version=$(
    awk '
      $0 == "  build_runner_accelerator:" { in_package=1; next }
      in_package && $0 ~ /^  [^[:space:]]/ { exit }
      in_package && $1 == "version:" {
        gsub(/^"/, "", $2)
        gsub(/"$/, "", $2)
        print $2
        exit
      }
    ' "$lockfile"
  )

  if [[ -z "$lock_version" ]]; then
    printf 'fixture lockfile check: missing build_runner_accelerator entry: %s\n' \
      "${lockfile#"$repo_root/"}" >&2
    status=1
  elif [[ "$lock_version" != "$root_version" ]]; then
    printf 'fixture lockfile check: %s has %s; expected %s\n' \
      "${lockfile#"$repo_root/"}" "$lock_version" "$root_version" >&2
    status=1
  fi
done < <(find "$repo_root/fixtures" -type f -name pubspec.lock -print | sort)

if ((checked == 0)); then
  printf 'fixture lockfile check: no accelerator fixture lockfiles found\n' >&2
  exit 1
fi

if ((status != 0)); then
  printf 'fixture lockfile check: run dart pub get in each affected fixture\n' >&2
  exit "$status"
fi

printf 'fixture lockfile check: %d fixture lockfiles match %s\n' "$checked" "$root_version"
