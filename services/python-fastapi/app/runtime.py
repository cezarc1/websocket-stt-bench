from __future__ import annotations

import logging
import os
import sys
import sysconfig
from collections.abc import Mapping
from importlib.metadata import version

# The one interpreter release this gateway ships on (versions.lock.toml
# [python]). Each image bakes PY_VERSION_EXPECTED and PY_GIL_DISABLED_EXPECTED
# from its Dockerfile build args; without them the free-threaded build of the
# pinned release is expected.
PINNED_PYTHON = (3, 15, 2)

type Version = tuple[int, int, int]


def expected_runtime(env: Mapping[str, str]) -> tuple[Version, bool]:
    """Return (exact Python version, GIL-disabled build?) this process must run on."""
    raw_version = env.get("PY_VERSION_EXPECTED")
    if raw_version is None:
        expected: Version = PINNED_PYTHON
    else:
        parts = raw_version.split(".")
        if len(parts) != 3 or not all(p.isdigit() for p in parts):
            raise RuntimeError(f"PY_VERSION_EXPECTED must be X.Y.Z, got {raw_version!r}")
        expected = (int(parts[0]), int(parts[1]), int(parts[2]))
    if expected != PINNED_PYTHON:
        raise RuntimeError(f"PY_VERSION_EXPECTED={expected} is not a pinned interpreter")

    # PY_VARIANT=gil is the original GIL-build switch; it must agree with the
    # explicit flag when both are present.
    variant_gil_disabled = env.get("PY_VARIANT", "ft") != "gil"
    raw_gil = env.get("PY_GIL_DISABLED_EXPECTED")
    if raw_gil is None:
        return expected, variant_gil_disabled
    if raw_gil not in ("0", "1"):
        raise RuntimeError(f"PY_GIL_DISABLED_EXPECTED must be 0 or 1, got {raw_gil!r}")
    gil_disabled = raw_gil == "1"
    if "PY_VARIANT" in env and gil_disabled != variant_gil_disabled:
        raise RuntimeError(
            f"PY_VARIANT={env['PY_VARIANT']!r} contradicts PY_GIL_DISABLED_EXPECTED={raw_gil}"
        )
    return expected, gil_disabled


def check_runtime(
    expected: Version,
    expect_gil_disabled: bool,
    actual: Version,
    py_gil_disabled: object,
    gil_enabled: bool | None,
) -> None:
    """Raise unless the interpreter matches exactly. gil_enabled is
    sys._is_gil_enabled() or None when the interpreter lacks it."""
    if actual != expected:
        raise RuntimeError(f"expected Python {expected}, got {actual}")
    if expect_gil_disabled:
        if py_gil_disabled != 1:
            raise RuntimeError("expected CPython free-threading build with Py_GIL_DISABLED=1")
        if gil_enabled is None:
            raise RuntimeError("expected sys._is_gil_enabled() on free-threading build")
        if gil_enabled:
            raise RuntimeError("expected free-threading runtime with the GIL disabled")
    else:
        if py_gil_disabled != 0:
            raise RuntimeError(
                f"expected regular GIL build with Py_GIL_DISABLED=0, got {py_gil_disabled}"
            )
        if gil_enabled is False:
            raise RuntimeError("expected the GIL to be enabled on the regular build")


def assert_runtime() -> None:
    expected, expect_gil_disabled = expected_runtime(os.environ)
    is_gil_enabled = getattr(sys, "_is_gil_enabled", None)
    check_runtime(
        expected,
        expect_gil_disabled,
        (sys.version_info.major, sys.version_info.minor, sys.version_info.micro),
        sysconfig.get_config_var("Py_GIL_DISABLED"),
        is_gil_enabled() if is_gil_enabled else None,
    )


def log_runtime_versions(logger: logging.Logger) -> None:
    granian_loops = os.getenv("GRANIAN_LOOPS")
    is_gil_enabled = getattr(sys, "_is_gil_enabled", None)
    fields = {
        "runtime": "python-fastapi",
        "py_variant": os.getenv("PY_VARIANT", "ft"),
        "python": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        "py_gil_disabled": sysconfig.get_config_var("Py_GIL_DISABLED"),
        "gil_enabled": is_gil_enabled() if is_gil_enabled else True,
        "aiohttp": version("aiohttp"),
        "fastapi": version("fastapi"),
        "granian": version("granian"),
        "pydantic": version("pydantic"),
        "uvloop": version("uvloop"),
        "granian_runtime_mode": "mt" if granian_loops else "st",
        "granian_loops": granian_loops or "1",
    }
    logger.info("runtime_versions %s", " ".join(f"{k}={v}" for k, v in fields.items()))
