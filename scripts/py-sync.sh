#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
MODE="${1:-sync}"
PYENV_NAME="$(version_value python pyenv)"
PY_EXE="$(version_value python executable)"
PYTHON_BIN="$(PYENV_VERSION="$PYENV_NAME" pyenv which "$PY_EXE")"
UV_BIN="$ROOT/.tools/bin/uv"

if [ "$MODE" = "lock" ]; then
  cd "$ROOT/services/python-fastapi"
  UV_PYTHON="$PYTHON_BIN" UV_PYTHON_PREFERENCE=only-system UV_PYTHON_DOWNLOADS=never "$UV_BIN" lock
elif [ "$MODE" = "sync" ]; then
  cd "$ROOT/services/python-fastapi"
  UV_PYTHON="$PYTHON_BIN" UV_PYTHON_PREFERENCE=only-system UV_PYTHON_DOWNLOADS=never "$UV_BIN" sync --locked
else
  echo "unknown py-sync mode: $MODE" >&2
  exit 2
fi
