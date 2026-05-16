"""pyperf microbench: baseline compute_stub vs. alt impls on realistic frames.

Run via: just py-bench  (writes results/python-bench-stub.json)

For lower noise on a quiet box: `pyperf system tune` first (Linux only;
needs root). On macOS, close other apps and accept the variance — pyperf
already does warmup + calibration + repeated runs and reports it.

This script is intentionally not a pytest test; pyperf forks subprocesses
to isolate each calibration run. Numeric correctness is verified by the
parity test, not here. Bench files are exempt from ruff PERF rules
because the point is to exercise the very patterns those rules dislike.
"""

from __future__ import annotations

import pyperf

from app.config import DEFAULT_CPU_PASSES
from app.stub import compute_stub
from tests.alt_impls import ALT_IMPLS
from tests.golden import make_realistic_frames


def main() -> None:
    runner = pyperf.Runner()
    frames = make_realistic_frames()

    runner.bench_func("baseline", compute_stub, frames, DEFAULT_CPU_PASSES)
    for name, impl in ALT_IMPLS:
        runner.bench_func(name, impl, frames, DEFAULT_CPU_PASSES)


if __name__ == "__main__":
    main()
