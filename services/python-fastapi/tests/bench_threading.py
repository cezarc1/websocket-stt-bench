"""Free-threading scaling experiment for compute_stub.

Measures throughput of N concurrent ThreadPoolExecutor workers each
running compute_stub on a fixed set of frames. Run twice — once under
the default 3.14t (no GIL), once with `python -X gil=1` — to A/B the
no-GIL build's headline feature on this exact workload.

Run via:
    just py-bench-threading

Output is plain text (workers, calls/sec, scaling factor vs workers=1)
because we want a tee-able artifact — pyperf's JSON is overkill for
this comparison.
"""

from __future__ import annotations

import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from app.config import DEFAULT_CPU_PASSES
from app.stub import compute_stub
from tests.golden import make_realistic_frames

WORKER_COUNTS: tuple[int, ...] = (1, 2, 4, 8)
CALLS_PER_WORKER: int = 200


def _gil_state() -> str:
    if hasattr(sys, "_is_gil_enabled"):
        return "off" if not sys._is_gil_enabled() else "on"
    return "n/a"


def measure(workers: int, calls_per_worker: int) -> float:
    frames = make_realistic_frames()
    barrier = threading.Barrier(workers)

    def task() -> None:
        barrier.wait()
        for _ in range(calls_per_worker):
            compute_stub(frames, DEFAULT_CPU_PASSES)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        t0 = time.perf_counter_ns()
        list(pool.map(lambda _: task(), range(workers)))
        return (time.perf_counter_ns() - t0) / 1e9


def main() -> None:
    print(f"# python={sys.version.split()[0]} gil={_gil_state()} pid={os.getpid()}")
    print(f"# calls_per_worker={CALLS_PER_WORKER} frames=13 passes={DEFAULT_CPU_PASSES}")
    print(f"{'workers':>7}  {'elapsed_s':>9}  {'calls/sec':>10}  {'scaling':>7}")

    baseline_throughput: float | None = None
    for workers in WORKER_COUNTS:
        elapsed = measure(workers, CALLS_PER_WORKER)
        total_calls = workers * CALLS_PER_WORKER
        throughput = total_calls / elapsed
        if baseline_throughput is None:
            baseline_throughput = throughput
        scaling = throughput / baseline_throughput
        print(f"{workers:>7d}  {elapsed:>9.3f}  {throughput:>10.1f}  {scaling:>6.2f}x")


if __name__ == "__main__":
    main()
