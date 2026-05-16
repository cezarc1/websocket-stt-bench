"""Golden vector + frame helpers shared by parity tests and benches.

The golden tuple was captured from the Rust reference implementation
(`services/rust-axum/src/main.rs::compute_stub`) running on the same
4-sample input that the Rust and Elixir test suites use. Bit-identical
output across the three implementations is a hard invariant of this repo
(see CLAUDE.md). If a Python rewrite ever diverges from these numbers,
that is the bug.
"""

from __future__ import annotations

import random
import struct

from app.protocol import FRAME_BYTES, Frame

GOLDEN_SAMPLES: tuple[int, ...] = (0, 100, -100, 200)
GOLDEN_PASSES: int = 4

GOLDEN_RMS: float = 122.47448713915891
GOLDEN_ZERO_CROSSINGS: int = 8
GOLDEN_CHECKSUM: int = 1_251_606_621
GOLDEN_SAMPLE_COUNT: int = 16


def golden_frame() -> Frame:
    payload = b"".join(struct.pack("<h", s) for s in GOLDEN_SAMPLES)
    return Frame(seq=1, payload=payload)


def make_realistic_frames(n_frames: int = 50, seed: int = 0xC0FFEE) -> list[Frame]:
    """50 frames of 640-byte seeded pseudo-random i16 samples.

    Matches the per-flush size the production gateway hands to compute_stub:
    1000 ms at 16 kHz / 20 ms-per-frame = 50 frames. Seeded so benches and
    parity checks operate on identical input across runs.
    """
    rng = random.Random(seed)
    samples_per_frame = FRAME_BYTES // 2
    frames: list[Frame] = []
    for seq in range(n_frames):
        samples = [rng.randint(-32_768, 32_767) for _ in range(samples_per_frame)]
        payload = struct.pack(f"<{samples_per_frame}h", *samples)
        frames.append(Frame(seq=seq, payload=payload))
    return frames
