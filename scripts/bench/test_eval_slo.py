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
        "sessions": 1,
        "partials": partials,
        "protocol_errors": protocol_errors,
        "inference_errors": inference_errors,
        "timeouts": {"connect": 0, "send": 0, "close": 0, "session": 0, **timeouts},
        "correctness_errors": 0,
        "verified_partials": partials,
        "verify_dropped": 0,
        "harness_faults": 0,
        "harness_lag_samples": 1000,
        "harness_lag": {"p50_ms": 1.0, "p99_ms": 3.0, "p999_ms": 30.0},
        "send_block": {"p99_ms": 0.0},
        "newest_frame_to_partial_latency": lat,
        "oldest_frame_to_partial_latency": {"p50_ms": 1100.0, "p95_ms": 1300.0},
        "flush_lateness": {"p95_ms": 1.0},
    }


def run(d):
    out = subprocess.run(
        [sys.executable, str(HERE / "eval_slo.py"), "N"],
        input=d if isinstance(d, str) else json.dumps(d),
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

    # Missing or truncated output is the harness's failure, never the gateway's.
    assert run("")[0] == "INVALID"
    assert run('{"partials": 10, "newest_fr')[0] == "INVALID"
    # Fields that used to default to zero now make the summary unjudgeable.
    for key in ("protocol_errors", "inference_errors", "verify_dropped", "harness_faults", "harness_lag", "timeouts"):
        d = summary(100)
        del d[key]
        verdict, out = run(d)
        assert verdict == "INVALID" and "malformed-summary" in out, (key, out)
    d = summary(100)
    d["newest_frame_to_partial_latency"]["p95_ms"] = float("nan")
    assert run(d)[0] == "INVALID"
    # A panicked session task lost its counters.
    d = summary(100)
    d["harness_faults"] = 1
    assert run(d)[0] == "INVALID"

    # A passing point must have every measured partial verified...
    d = summary(100)
    d["verified_partials"], d["verify_dropped"] = 90, 10
    verdict, out = run(d)
    assert verdict == "INVALID" and "verification-incomplete" in out, out
    d = summary(100)
    d["verified_partials"] = 50  # --verify-every 2
    assert run(d)[0] == "INVALID"
    # ...but a gateway FAIL on observed evidence stands without full coverage.
    d = summary(100)
    d["verified_partials"], d["verify_dropped"], d["correctness_errors"] = 90, 10, 1
    assert run(d)[0] == "FAIL"
    d = summary(100)
    d["verified_partials"], d["verify_dropped"] = 90, 10
    d["newest_frame_to_partial_latency"]["p50_ms"] = 250.0
    assert run(d)[0] == "FAIL"

    # Loadgen send lag makes a PASS INVALID too (it changes the workload).
    d = summary(100)
    d["harness_lag"]["p99_ms"] = 31.0
    verdict, out = run(d)
    assert verdict == "INVALID" and "harness_lag_p99" in out, out
    # Unless the lag is the gateway's back-pressure.
    d["send_block"]["p99_ms"] = 40.0
    assert run(d)[0] == "PASS"
    print("test_eval_slo: ok")


if __name__ == "__main__":
    main()
