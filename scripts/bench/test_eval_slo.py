#!/usr/bin/env python3
# Plain-python3 tests for eval_slo.py (no pytest needed):
#   python3 scripts/bench/test_eval_slo.py
import doctest
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eval_slo  # noqa: E402


def summary(partials, protocol_errors=0, inference_errors=0, **timeouts):
    lat = {"p50_ms": 100.0, "p95_ms": 200.0}
    return {
        "partials": partials,
        "protocol_errors": protocol_errors,
        "inference_errors": inference_errors,
        "timeouts": {"connect": 0, "send": 0, "close": 0, "session": 0, **timeouts},
        "correctness_errors": 0,
        "verified_partials": 10,
        "newest_frame_to_partial_latency": lat,
        "oldest_frame_to_partial_latency": {"p50_ms": 1100.0, "p95_ms": 1300.0},
        "flush_lateness": {"p95_ms": 1.0},
    }


def run(d):
    out = subprocess.run(
        [sys.executable, str(HERE / "eval_slo.py"), "N"],
        input=json.dumps(d),
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return out.split()[1], out


def main():
    failures, _ = doctest.testmod(eval_slo)
    assert failures == 0, f"{failures} doctest failure(s)"

    # Timeouts are already inside protocol_errors: 2 failed sessions, not 4.
    assert eval_slo.count_errors(summary(1, 2, connect=2)) == 2
    # Non-timeout failures + error frames are distinct and both count.
    assert eval_slo.count_errors(summary(1, 1, 1)) == 2
    assert eval_slo.count_errors(summary(1, 3, 0, send=1, close=1)) == 3

    # Budget is 1e-5: 2 errors pass at 200k partials (1e-5), 3 do not.
    # Old evaluator would count 2+2=4 here and FAIL.
    verdict, out = run(summary(200_000, 2, connect=2))
    assert verdict == "PASS", out
    assert "err=2 " in out, out
    verdict, out = run(summary(200_000, 3, connect=2))
    assert verdict == "FAIL" and "err_rate" in out, out
    # Inference error frames still count on top of failed sessions.
    verdict, out = run(summary(200_000, 2, 1, connect=2))
    assert verdict == "FAIL" and "(3/200000)" in out, out
    # Clean run passes; zero partials fails.
    assert run(summary(100))[0] == "PASS"
    assert run(summary(0))[0] == "FAIL"
    print("test_eval_slo: ok")


if __name__ == "__main__":
    main()
