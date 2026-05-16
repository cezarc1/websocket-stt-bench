ARG PYTHON_FT_IMAGE=quay.io/pypa/manylinux_2_28_aarch64@sha256:c269bed3fc0ba21aac08ff67bf1d657d4967a9c0582fc8880a0e302f8ca78bdd
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.7@sha256:240fb85ab0f263ef12f492d8476aa3a2e4e1e333f7d67fbdd923d00a506a516a

# PY_VARIANT selects between the free-threaded build (default, "ft") and the
# GIL-enabled build ("gil"). The manylinux base ships both /opt/python/cp314-cp314t
# (FT) and /opt/python/cp314-cp314 (regular). Compose passes the gil trio for
# the experimental python-fastapi-stock-gil-single service.
ARG PY_VARIANT=ft
ARG PY_DIR=cp314-cp314t
ARG PY_EXE=python3.14t
ARG PY_GIL_DISABLED_EXPECTED=1

FROM ${UV_IMAGE} AS uv-bin

FROM ${PYTHON_FT_IMAGE} AS app-build

ARG UV_VERSION=0.11.7
ARG PY_VARIANT
ARG PY_DIR
ARG PY_EXE
ARG PY_GIL_DISABLED_EXPECTED

ENV PATH="/opt/python/${PY_DIR}/bin:/opt/uv:${PATH}" \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON=/opt/python/${PY_DIR}/bin/${PY_EXE} \
    UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-system \
    PYTHONUNBUFFERED=1 \
    PY_VARIANT=${PY_VARIANT} \
    PY_EXE=${PY_EXE} \
    PY_GIL_DISABLED_EXPECTED=${PY_GIL_DISABLED_EXPECTED}

RUN ${PY_EXE} - <<PY
import sys
import sysconfig

assert sys.version_info[:3] == (3, 14, 4), sys.version
expected_gil_disabled = int("${PY_GIL_DISABLED_EXPECTED}")
assert sysconfig.get_config_var("Py_GIL_DISABLED") == expected_gil_disabled, \
    f"expected Py_GIL_DISABLED={expected_gil_disabled}"
if expected_gil_disabled == 1:
    assert not sys._is_gil_enabled(), "free-threaded build must report GIL disabled"
PY

COPY --from=uv-bin /uv /uvx /opt/uv/
RUN /opt/uv/uv --version | grep -q "^uv ${UV_VERSION} "

RUN mkdir -p /opt/python-runtime-libs \
  && cp -L \
    /lib64/libbz2.so.1 \
    /lib64/libcrypto.so.1.1 \
    /lib64/libffi.so.6 \
    /lib64/libgdbm.so.6 \
    /lib64/libgdbm_compat.so.4 \
    /lib64/liblzma.so.5 \
    /lib64/libncursesw.so.6 \
    /lib64/libpanelw.so.6 \
    /lib64/libreadline.so.7 \
    /lib64/libssl.so.1.1 \
    /lib64/libtcl8.6.so \
    /lib64/libtinfo.so.6 \
    /lib64/libtk8.6.so \
    /lib64/libuuid.so.1 \
    /lib64/libz.so.1 \
    /lib64/libzstd.so.1 \
    /opt/python-runtime-libs/

WORKDIR /app
COPY services/python-fastapi/pyproject.toml services/python-fastapi/uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
  uv sync --locked --no-dev --no-install-project

FROM debian:bookworm-20260421-slim

ARG PY_VARIANT
ARG PY_DIR
ARG PY_EXE
ARG PY_GIL_DISABLED_EXPECTED

ENV PATH="/app/.venv/bin:/opt/python/${PY_DIR}/bin:/opt/uv:${PATH}" \
    LD_LIBRARY_PATH="/opt/python-runtime-libs" \
    UV_PYTHON=/opt/python/${PY_DIR}/bin/${PY_EXE} \
    UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-system \
    PYTHONUNBUFFERED=1 \
    VIRTUAL_ENV=/app/.venv \
    PY_VARIANT=${PY_VARIANT} \
    PY_EXE=${PY_EXE} \
    PY_GIL_DISABLED_EXPECTED=${PY_GIL_DISABLED_EXPECTED}

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=app-build /opt/python/${PY_DIR} /opt/python/${PY_DIR}
COPY --from=app-build /opt/python-runtime-libs /opt/python-runtime-libs
COPY --from=app-build /opt/_internal/mpdecimal-4 /opt/_internal/mpdecimal-4
COPY --from=app-build /opt/_internal/sqlite3 /opt/_internal/sqlite3
COPY --from=app-build /opt/uv /opt/uv

RUN ${PY_EXE} - <<PY
import decimal
import ssl
import sqlite3
import sys
import sysconfig

assert sys.version_info[:3] == (3, 14, 4), sys.version
expected_gil_disabled = int("${PY_GIL_DISABLED_EXPECTED}")
assert sysconfig.get_config_var("Py_GIL_DISABLED") == expected_gil_disabled, \
    f"expected Py_GIL_DISABLED={expected_gil_disabled}"
if expected_gil_disabled == 1:
    assert not sys._is_gil_enabled()
assert ssl.OPENSSL_VERSION.startswith("OpenSSL 1.1.1"), ssl.OPENSSL_VERSION
assert sqlite3.sqlite_version
assert decimal.Decimal("1.25")
PY

WORKDIR /app
COPY --from=app-build /app/.venv ./.venv
COPY services/python-fastapi/pyproject.toml services/python-fastapi/uv.lock ./
COPY services/python-fastapi/app ./app
COPY docker/python-launch.sh /usr/local/bin/python-launch.sh
RUN chmod +x /usr/local/bin/python-launch.sh

ENV PORT=8000
EXPOSE 8000
CMD ["/usr/local/bin/python-launch.sh"]
