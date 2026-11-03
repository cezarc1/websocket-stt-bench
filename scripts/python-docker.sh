#!/usr/bin/env bash
# Python gateway tooling. The pinned CPython 3.15.2 / 3.15.2t interpreters are
# container-only (manylinux image pinned in versions.lock.toml), so every mode
# runs through docker/python-fastapi.Dockerfile on the native platform:
#   check            ruff format --check, ruff check, ty, pytest in the `test`
#                    stage, for 3.15.2t (free-threading) and 3.15.2 (GIL).
#   lock             `uv lock` in the `toolchain` stage, writing
#                    services/python-fastapi/uv.lock.
#   bench-threading  tests/bench_threading.py on 3.15.2t with -X gil=0 and
#                    -X gil=1, output under results/.
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
cd "$ROOT"
MODE="${1:-check}"
case "$(uname -m)" in
  arm64 | aarch64) ARCH=aarch64 ;;
  *) ARCH=x86_64 ;;
esac
IMAGE="$(version_value containers.python "manylinux_2_28_$ARCH")"
VERSION="$(version_value python version)"
UV_IMAGE="$(version_value containers.uv distroless)"
UV_VERSION="$(version_value tools uv)"
FT_EXE="$(version_value python executable)"
GIL_EXE="$(version_value python executable_gil)"

common=(
  -f docker/python-fastapi.Dockerfile
  --build-arg "PYTHON_FT_IMAGE=$IMAGE"
  --build-arg "UV_IMAGE=$UV_IMAGE"
  --build-arg "UV_VERSION=$UV_VERSION"
  --build-arg "PY_VERSION_EXPECTED=$VERSION"
)
ft=(--build-arg PY_DIR=cp315-cp315t --build-arg "PY_EXE=$FT_EXE")
gil=(
  --build-arg PY_VARIANT=gil --build-arg PY_DIR=cp315-cp315 --build-arg "PY_EXE=$GIL_EXE"
  --build-arg PY_GIL_DISABLED_EXPECTED=0
)

case "$MODE" in
  check)
    echo "python-check: $FT_EXE $VERSION (free-threading)"
    docker buildx build --target test --progress plain "${common[@]}" "${ft[@]}" .
    echo "python-check: $GIL_EXE $VERSION (GIL)"
    docker buildx build --target test --progress plain "${common[@]}" "${gil[@]}" .
    ;;
  lock)
    tag="stt-python-fastapi-toolchain:$VERSION"
    docker buildx build --target toolchain --load -t "$tag" "${common[@]}" "${ft[@]}" .
    docker run --rm -v "$ROOT/services/python-fastapi:/work" -w /work "$tag" uv lock
    ;;
  bench-threading)
    tag="stt-python-fastapi-test:$VERSION-ft"
    docker buildx build --target test --load -t "$tag" "${common[@]}" "${ft[@]}" .
    mkdir -p results
    for gil_flag in 0 1; do
      name=$([ "$gil_flag" = 0 ] && echo nogil || echo gil)
      docker run --rm -e PYTHONPATH=. "$tag" .venv/bin/python -X "gil=$gil_flag" \
        tests/bench_threading.py | tee "results/python-bench-threading-$name.txt"
    done
    ;;
  *)
    echo "unknown mode: $MODE (expected check, lock or bench-threading)" >&2
    exit 2
    ;;
esac
