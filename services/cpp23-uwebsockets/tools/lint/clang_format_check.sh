#!/usr/bin/env bash
# Usage: clang_format_check.sh <clang-format> <.clang-format> <files...>
set -euo pipefail

clang_format=$1
style=$2
shift 2
[ $# -gt 0 ] || { echo "clang-format: no files to check" >&2; exit 1; }

"${clang_format}" --version
"${clang_format}" --style="file:${style}" --dry-run --Werror "$@"
echo "clang-format: $# files clean"
