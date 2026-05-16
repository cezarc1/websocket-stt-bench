"""Numeric-equivalence gate for compute_stub.

Failing this test means the Python implementation drifted from the Rust
and Elixir reference implementations — the load-generator's checksum
oracle would start flagging Python partials. Treat as P0.
"""

from __future__ import annotations

import math

import pytest

from app.stub import compute_stub
from tests.alt_impls import ALT_IMPLS
from tests.golden import (
    GOLDEN_CHECKSUM,
    GOLDEN_PASSES,
    GOLDEN_RMS,
    GOLDEN_SAMPLE_COUNT,
    GOLDEN_ZERO_CROSSINGS,
    golden_frame,
    make_realistic_frames,
)


def test_baseline_matches_golden() -> None:
    result = compute_stub([golden_frame()], GOLDEN_PASSES)

    assert result.checksum == GOLDEN_CHECKSUM
    assert result.zero_crossings == GOLDEN_ZERO_CROSSINGS
    assert result.samples == GOLDEN_SAMPLE_COUNT
    assert math.isclose(result.rms, GOLDEN_RMS, abs_tol=1e-9)


def test_empty_frames_returns_zero() -> None:
    result = compute_stub([], GOLDEN_PASSES)

    assert result.samples == 0
    assert result.zero_crossings == 0
    assert result.rms == 0.0


@pytest.mark.parametrize(("name", "impl"), ALT_IMPLS, ids=[name for name, _ in ALT_IMPLS])
def test_alt_impl_matches_baseline_on_golden(name: str, impl) -> None:
    baseline = compute_stub([golden_frame()], GOLDEN_PASSES)
    candidate = impl([golden_frame()], GOLDEN_PASSES)

    assert candidate.checksum == baseline.checksum, name
    assert candidate.zero_crossings == baseline.zero_crossings, name
    assert candidate.samples == baseline.samples, name
    assert math.isclose(candidate.rms, baseline.rms, abs_tol=1e-9), name


@pytest.mark.parametrize(("name", "impl"), ALT_IMPLS, ids=[name for name, _ in ALT_IMPLS])
def test_alt_impl_matches_baseline_on_realistic_frames(name: str, impl) -> None:
    frames = make_realistic_frames()
    baseline = compute_stub(frames, GOLDEN_PASSES)
    candidate = impl(frames, GOLDEN_PASSES)

    assert candidate.checksum == baseline.checksum, name
    assert candidate.zero_crossings == baseline.zero_crossings, name
    assert candidate.samples == baseline.samples, name
    assert math.isclose(candidate.rms, baseline.rms, abs_tol=1e-9), name
