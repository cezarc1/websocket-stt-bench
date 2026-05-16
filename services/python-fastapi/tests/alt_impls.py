"""Alternative compute_stub implementations evaluated against the baseline.

Each must be bit-identical to `app.stub.compute_stub` for arbitrary input.
The parity test is the gate: if an implementation here drifts, the bench
will not run it. None of these are imported by the runtime — they live
solely under `tests/` so the production image stays free of numpy and
incidental complexity.
"""

from __future__ import annotations

import array
import math
import struct
from collections.abc import Iterable

import numpy as np

from app.protocol import Frame
from app.stub import StubResult

_FNV_OFFSET = 2_166_136_261
_FNV_PRIME = 16_777_619
_U32_MASK = 0xFFFF_FFFF
_U16_MASK = 0xFFFF


def compute_stub_memoryview(frames: Iterable[Frame], passes: int) -> StubResult:
    """Drop the intermediate sample list; iterate i16 samples via struct.unpack_from."""
    payload = b"".join(frame.payload for frame in frames)
    view = memoryview(payload)
    n_samples = len(view) // 2

    checksum = _FNV_OFFSET
    zero_crossings = 0
    sum_squares = 0
    sample_count = 0
    previous = 0

    for pass_index in range(passes):
        for i in range(n_samples):
            (sample,) = struct.unpack_from("<h", view, i * 2)
            if sample_count > 0 and (sample < 0 <= previous or previous < 0 <= sample):
                zero_crossings += 1
            adjusted = sample + 32_768 + pass_index
            checksum ^= adjusted & _U16_MASK
            checksum = (checksum * _FNV_PRIME) & _U32_MASK
            sum_squares += sample * sample
            sample_count += 1
            previous = sample

    if sample_count == 0:
        return StubResult(rms=0.0, zero_crossings=0, checksum=checksum, samples=0)
    return StubResult(
        rms=math.sqrt(sum_squares / sample_count),
        zero_crossings=zero_crossings,
        checksum=checksum,
        samples=sample_count,
    )


def compute_stub_array(frames: Iterable[Frame], passes: int) -> StubResult:
    """Bulk-decode all i16 samples once via array.array, then iterate plain ints."""
    payload = b"".join(frame.payload for frame in frames)
    samples = array.array("h")
    samples.frombytes(payload)

    checksum = _FNV_OFFSET
    zero_crossings = 0
    sum_squares = 0
    sample_count = 0
    previous = 0

    for pass_index in range(passes):
        for sample in samples:
            if sample_count > 0 and (sample < 0 <= previous or previous < 0 <= sample):
                zero_crossings += 1
            adjusted = sample + 32_768 + pass_index
            checksum ^= adjusted & _U16_MASK
            checksum = (checksum * _FNV_PRIME) & _U32_MASK
            sum_squares += sample * sample
            sample_count += 1
            previous = sample

    if sample_count == 0:
        return StubResult(rms=0.0, zero_crossings=0, checksum=checksum, samples=0)
    return StubResult(
        rms=math.sqrt(sum_squares / sample_count),
        zero_crossings=zero_crossings,
        checksum=checksum,
        samples=sample_count,
    )


def compute_stub_split(frames: Iterable[Frame], passes: int) -> StubResult:
    """Vectorize sum_squares + zero_crossings (pass-invariant); keep FNV sequential.

    sum_squares and zero_crossings only depend on the sample sequence, not on
    pass_index — they end up multiplied by `passes`. We compute them once with
    numpy and scale. The FNV-1a state IS pass-dependent, so it stays in a
    pure-Python loop.
    """
    payload = b"".join(frame.payload for frame in frames)
    if not payload:
        return StubResult(rms=0.0, zero_crossings=0, checksum=_FNV_OFFSET, samples=0)

    arr = np.frombuffer(payload, dtype=np.int16)
    n = arr.size

    # Sum of squares: cast to int64 to match Rust's i128 semantics for our sizes.
    # i16² ≤ 32768² ~ 1.07e9; sum over <= ~1M samples per call stays well under i64.
    sum_squares_per_pass = int(np.sum(arr.astype(np.int64) ** 2))

    # Zero crossings: pairs (prev, cur) where signs cross. Match the
    # baseline's exact rule including the boundary across passes.
    if n >= 2:
        prev = arr[:-1]
        cur = arr[1:]
        crossings_intra = int(np.sum(((cur < 0) & (prev >= 0)) | ((prev < 0) & (cur >= 0))))
    else:
        crossings_intra = 0
    # For pass i > 0, the boundary uses arr[-1] (previous pass last) and arr[0] (this pass first).
    if n >= 1:
        last, first = int(arr[-1]), int(arr[0])
        boundary = int((first < 0 and last >= 0) or (last < 0 and first >= 0))
    else:
        boundary = 0
    zero_crossings = passes * crossings_intra + (passes - 1) * boundary

    sum_squares = passes * sum_squares_per_pass
    sample_count = passes * n

    # FNV-1a, one pure-Python loop — pass_index changes the input each pass.
    checksum = _FNV_OFFSET
    samples_list = arr.tolist()
    for pass_index in range(passes):
        for sample in samples_list:
            adjusted = sample + 32_768 + pass_index
            checksum ^= adjusted & _U16_MASK
            checksum = (checksum * _FNV_PRIME) & _U32_MASK

    if sample_count == 0:
        return StubResult(rms=0.0, zero_crossings=0, checksum=checksum, samples=0)
    return StubResult(
        rms=math.sqrt(sum_squares / sample_count),
        zero_crossings=zero_crossings,
        checksum=checksum,
        samples=sample_count,
    )


ALT_IMPLS = (
    ("memoryview", compute_stub_memoryview),
    ("array", compute_stub_array),
    ("split", compute_stub_split),
)
