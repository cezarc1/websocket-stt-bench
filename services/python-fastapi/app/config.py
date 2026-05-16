from __future__ import annotations

import os

DEFAULT_FLUSH_INTERVAL_MS = 1000
DEFAULT_CPU_PASSES = 4
DEFAULT_MODEL_DELAY_MS = 75
DEFAULT_FLUSH_PHASE_JITTER_MS = 0
DEFAULT_INFERENCE_URL = "http://inference-server:9000"
# Mirrors `PARTIAL_CHANNEL_DEPTH` in services/rust-axum/src/config.rs so the
# two gateways share the same outbound backpressure regime.
PARTIAL_CHANNEL_DEPTH = 4


def settings_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    value = int(raw)
    if value < 0:
        raise ValueError(f"{name} must be non-negative")
    return value
