#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
if rg -n ':(latest|stable|main|master)([^A-Za-z0-9_.-]|$)' "$ROOT/docker" "$ROOT/docker-compose.yml" >/tmp/websocket-stt-bench-moving-tags.txt 2>/dev/null; then
  cat /tmp/websocket-stt-bench-moving-tags.txt >&2
  echo "moving Docker tags are not allowed" >&2
  exit 1
fi

echo "docker tag check ok"
