#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export WEB_COMPILERS_FIXTURE=build_web_compilers_ddc_app
export WEB_COMPILERS_MODE=ddc
exec bash "$script_dir/watch_smoke_web_compilers.sh" "$@"
