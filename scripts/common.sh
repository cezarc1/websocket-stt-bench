#!/usr/bin/env bash
set -euo pipefail

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

version_value() {
  local section="$1"
  local key="$2"
  awk -F\" -v section="$section" -v key="$key" '
    /^\[/ {
      current = $0
      gsub(/^\[/, "", current)
      gsub(/\]$/, "", current)
    }
    current == section && $1 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print $2
      exit
    }
  ' "$(repo_root)/versions.lock.toml"
}
