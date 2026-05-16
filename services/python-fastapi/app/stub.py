from __future__ import annotations

import math
import struct
from collections.abc import Iterable
from dataclasses import dataclass

from app.protocol import Frame

_FNV_OFFSET = 2_166_136_261
_FNV_PRIME = 16_777_619


@dataclass(slots=True, frozen=True)
class StubResult:
    rms: float
    zero_crossings: int
    checksum: int
    samples: int


def compute_stub(frames: Iterable[Frame], passes: int) -> StubResult:
    payload = b"".join(frame.payload for frame in frames)
    samples = [s for (s,) in struct.iter_unpack("<h", payload)]
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
            checksum ^= adjusted & 0xFFFF
            checksum = (checksum * _FNV_PRIME) & 0xFFFF_FFFF
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
