#!/usr/bin/env bash
# CPython 3.15 lane gate: the 3.15 interpreters are container-only, so run
# pytest + ty in the python-fastapi Dockerfile's `test` stage for 3.15.2t and
# 3.15.2 (native platform, same digest pins as the images). ruff is
# interpreter-independent and already covered by `just python-check`.
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
cd "$ROOT"
case "$(uname -m)" in
  arm64 | aarch64) ARCH=aarch64 ;;
  *) ARCH=x86_64 ;;
esac
IMAGE="$(version_value containers.python315 "manylinux_2_28_$ARCH")"
VERSION="$(version_value python315 version)"
UV_IMAGE="$(version_value containers.uv distroless)"
UV_VERSION="$(version_value tools uv)"
FT_EXE="$(version_value python315 executable)"
GIL_EXE="$(version_value python315 executable_gil)"

common=(
  --build-arg "PYTHON_FT_IMAGE=$IMAGE"
  --build-arg "UV_IMAGE=$UV_IMAGE"
  --build-arg "UV_VERSION=$UV_VERSION"
  --build-arg "PY_VERSION_EXPECTED=$VERSION"
  --build-arg "PY_PROJECT_DIR=services/python-fastapi/py315"
)
echo "py315-check: $FT_EXE (free-threading)"
docker buildx build --target test --progress plain -f docker/python-fastapi.Dockerfile "${common[@]}" \
  --build-arg PY_DIR=cp315-cp315t --build-arg "PY_EXE=$FT_EXE" .
echo "py315-check: $GIL_EXE (GIL)"
docker buildx build --target test --progress plain -f docker/python-fastapi.Dockerfile "${common[@]}" \
  --build-arg PY_VARIANT=gil --build-arg PY_DIR=cp315-cp315 --build-arg "PY_EXE=$GIL_EXE" \
  --build-arg PY_GIL_DISABLED_EXPECTED=0 .
