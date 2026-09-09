#!/usr/bin/env bash
set -euo pipefail
root="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
host="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$host" in darwin) host=macos;; msys*|mingw*|cygwin*) host=windows;; esac
platforms="${AOT_MATRIX_PLATFORMS:-linux,macos,windows}"
sdk_list="${AOT_MATRIX_SDKS:-${DART_BIN:-dart}}"
cases="${AOT_MATRIX_CASES:-current_json_app,multi_mapping_builder_app}"
out="${AOT_MATRIX_OUTPUT:-$root/.dart_tool/build_runner_accelerator/aot-matrix.tsv}"
mkdir -p "$(dirname "$out")"
printf 'platform\tsdk\tworkspace\tresult\tdetail\n' > "$out"
IFS=, read -ra ps <<< "$platforms"
IFS=; read -ra sdks <<< "$sdk_list"
IFS=, read -ra cs <<< "$cases"
for p in "${ps[@]}"; do for sdk in "${sdks[@]}"; do for c in "${cs[@]}"; do
  if [[ "$p" != "$host" ]]; then
    printf '%s\t%s\t%s\tskipped\tnot-local-host\n' "$p" "$sdk" "$c" >> "$out"; continue
  fi
  case "$c" in
    current_json_app) check="$root/scripts/correctness_aot_worker.sh";;
    multi_mapping_builder_app) check="$root/scripts/correctness_multi_mapping_builder.sh";;
    arbitrary_dependency_app) check="$root/scripts/correctness_arbitrary_dependency_builder.sh";;
    *) printf '%s\t%s\t%s\tskipped\tunknown-case\n' "$p" "$sdk" "$c" >> "$out"; continue;;
  esac
  if DART_BIN="$sdk" "$check" >/tmp/build-runner-accelerator-aot-matrix.log 2>&1; then
    printf '%s\t%s\t%s\tpassed\tlocal\n' "$p" "$sdk" "$c" >> "$out"
  else
    printf '%s\t%s\t%s\tfailed\t%s\n' "$p" "$sdk" "$c" "$(tail -n 1 /tmp/build-runner-accelerator-aot-matrix.log)" >> "$out"
    cat /tmp/build-runner-accelerator-aot-matrix.log >&2
    exit 1
  fi
done; done; done
cat "$out"