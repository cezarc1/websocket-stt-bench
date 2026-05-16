from __future__ import annotations

import logging
import os
import sys
import sysconfig
from importlib.metadata import version

EXPECTED_PYTHON = (3, 14, 4)


def assert_runtime() -> None:
    if sys.version_info[:3] != EXPECTED_PYTHON:
        raise RuntimeError(f"expected Python {EXPECTED_PYTHON}, got {sys.version_info[:3]}")
    # The python-fastapi-stock-gil-single experiment runs on the regular 3.14
    # build to quantify free-threading's overhead on a single-threaded loop.
    # The FT-specific assertions below don't apply there.
    if os.getenv("PY_VARIANT") == "gil":
        return
    if sysconfig.get_config_var("Py_GIL_DISABLED") != 1:
        raise RuntimeError("expected CPython free-threading build with Py_GIL_DISABLED=1")
    if not hasattr(sys, "_is_gil_enabled"):
        raise RuntimeError("expected sys._is_gil_enabled() on free-threading build")
    if sys._is_gil_enabled():
        raise RuntimeError("expected free-threading runtime with the GIL disabled")


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
        "granian_runtime_mode": "mt" if granian_loops else "st",
        "granian_loops": granian_loops or "1",
    }
    logger.info("runtime_versions %s", " ".join(f"{k}={v}" for k, v in fields.items()))
