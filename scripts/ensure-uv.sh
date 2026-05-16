#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
UV_VERSION="$(version_value tools uv)"
UV_DIR="$ROOT/.tools/bin"
UV_BIN="$UV_DIR/uv"

if [ -x "$UV_BIN" ] && "$UV_BIN" --version | grep -q "^uv $UV_VERSION "; then
  exit 0
fi

mkdir -p "$UV_DIR"
curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" | env UV_INSTALL_DIR="$UV_DIR" sh

"$UV_BIN" --version | grep -q "^uv $UV_VERSION "
