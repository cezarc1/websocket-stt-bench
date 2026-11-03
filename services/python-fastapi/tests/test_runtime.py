"""Runtime guard: each image must assert its own exact interpreter and GIL state."""

from __future__ import annotations

import sys
import sysconfig

import pytest

from app.runtime import assert_runtime, check_runtime, expected_runtime

PY315 = (3, 15, 2)
PY314 = (3, 14, 4)  # the removed lane: must now be rejected everywhere


@pytest.mark.parametrize(
    ("env", "expected"),
    [
        ({}, (PY315, True)),
        ({"PY_VARIANT": "gil"}, (PY315, False)),
        ({"PY_VERSION_EXPECTED": "3.15.2", "PY_GIL_DISABLED_EXPECTED": "1"}, (PY315, True)),
        (
            {"PY_VERSION_EXPECTED": "3.15.2", "PY_GIL_DISABLED_EXPECTED": "0", "PY_VARIANT": "gil"},
            (PY315, False),
        ),
        ({"PY_VERSION_EXPECTED": "3.15.2", "PY_VARIANT": "ft"}, (PY315, True)),
    ],
)
def test_expected_runtime_from_image_env(
    env: dict[str, str], expected: tuple[tuple[int, int, int], bool]
) -> None:
    assert expected_runtime(env) == expected


@pytest.mark.parametrize(
    "env",
    [
        {"PY_VERSION_EXPECTED": "3.15"},
        {"PY_VERSION_EXPECTED": "3.15.2t"},
        {"PY_VERSION_EXPECTED": "3.15.1"},  # not a pinned release
        {"PY_VERSION_EXPECTED": "3.14.4"},  # removed lane
        {"PY_VERSION_EXPECTED": "3.14.4", "PY_GIL_DISABLED_EXPECTED": "1"},
        {"PY_VERSION_EXPECTED": "3.14.10"},
        {"PY_GIL_DISABLED_EXPECTED": "true"},
        {"PY_GIL_DISABLED_EXPECTED": ""},
        {"PY_VARIANT": "gil", "PY_GIL_DISABLED_EXPECTED": "1"},
        {"PY_VARIANT": "ft", "PY_GIL_DISABLED_EXPECTED": "0"},
    ],
)
def test_expected_runtime_rejects_bad_or_contradictory_env(env: dict[str, str]) -> None:
    with pytest.raises(RuntimeError):
        expected_runtime(env)


def test_check_runtime_accepts_exact_matches() -> None:
    check_runtime(PY315, True, PY315, 1, False)
    check_runtime(PY315, False, PY315, 0, True)


@pytest.mark.parametrize(
    ("expected", "expect_ft", "actual", "py_gil_disabled", "gil_enabled"),
    [
        (PY315, True, PY314, 1, False),  # 3.15 image running 3.14
        (PY315, False, PY314, 0, True),  # 3.15 GIL image running 3.14
        (PY315, True, (3, 15, 1), 1, False),  # wrong patch release
        (PY315, True, PY315, 0, True),  # FT image on the GIL build
        (PY315, True, PY315, 1, True),  # FT build with the GIL re-enabled
        (PY315, True, PY315, 1, None),  # FT build without sys._is_gil_enabled
        (PY315, False, PY315, 1, False),  # GIL image on the FT build
        (PY315, False, PY315, 1, True),  # GIL image on FT build even if GIL re-enabled
        (PY315, False, PY315, None, True),  # unknown build config
    ],
)
def test_check_runtime_rejects_mismatches(
    expected: tuple[int, int, int],
    expect_ft: bool,
    actual: tuple[int, int, int],
    py_gil_disabled: object,
    gil_enabled: bool | None,
) -> None:
    with pytest.raises(RuntimeError):
        check_runtime(expected, expect_ft, actual, py_gil_disabled, gil_enabled)


def test_assert_runtime_matches_this_interpreter(monkeypatch: pytest.MonkeyPatch) -> None:
    # Both images' test stages (3.15.2t and 3.15.2) run the suite: the guard
    # must accept the interpreter when told the truth and reject the opposite
    # GIL state.
    ft = sysconfig.get_config_var("Py_GIL_DISABLED") == 1
    monkeypatch.delenv("PY_VARIANT", raising=False)
    monkeypatch.setenv("PY_VERSION_EXPECTED", "{}.{}.{}".format(*sys.version_info[:3]))
    monkeypatch.setenv("PY_GIL_DISABLED_EXPECTED", "1" if ft else "0")
    assert_runtime()
    monkeypatch.setenv("PY_GIL_DISABLED_EXPECTED", "0" if ft else "1")
    with pytest.raises(RuntimeError):
        assert_runtime()
