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


# --- Loadgen frame generator port -------------------------------------------
# Independent Python port of `loadgen/rust/src/protocol.rs::frame_payload`, so
# the loadgen/conformance goldens (GOLDEN_ONE_FRAME and the 50-frame golden in
# `loadgen/rust/src/verify.rs`) are cross-checked against this reference stub
# rather than only against the Rust stub that produced them.

_U64 = (1 << 64) - 1
_SPLITMIX_GAMMA = 0x9E37_79B9_7F4A_7C15
SAMPLES_PER_FRAME = FRAME_BYTES // 2


def _mix64(z: int) -> int:
    z = ((z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9) & _U64
    z = ((z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB) & _U64
    return z ^ (z >> 31)


def loadgen_frame_payload(session_id: int, seq: int) -> bytes:
    state = _mix64(_mix64(session_id) ^ seq)
    carrier = state % 20_000
    samples = []
    for _ in range(SAMPLES_PER_FRAME // 4):
        state = (state + _SPLITMIX_GAMMA) & _U64
        noise = _mix64(state)
        for lane in range(4):
            jitter = ((noise >> (16 * lane)) & 0x1FF) - 256
            samples.append(carrier - 10_000 + jitter)
            carrier = (carrier + 17) % 20_000
    return struct.pack(f"<{len(samples)}h", *samples)


# (session_id, oldest, newest) -> (checksum, zero_crossings, samples, rms,
# transcript) at 4 passes. Mirrors the Rust constants exactly.
LOADGEN_GOLDENS: dict[tuple[int, int, int], tuple[int, int, int, float, str]] = {
    (0, 1, 1): (763_539_697, 7, 1_280, 8_323.765219801373, "quick"),
    (7_919, 1, 50): (3_451_184_229, 736, 64_000, 5_956.275069978719, "now"),
}

# Copy of `crates/stt-stub/src/lib.rs::TRANSCRIPT_POOL`; the Python stub does
# not compute transcripts, so the parity test applies checksum % len here.
TRANSCRIPT_POOL: tuple[str, ...] = (
    "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "hello", "world",
    "yes", "no", "okay", "right", "left", "stop", "go", "wait", "ready", "done",
    "again", "now", "later", "never",
)  # fmt: skip
