#!/usr/bin/env python3
# Evaluate one loadgen summary JSON (stdin) against the websocket-stt-bench
# SLO gates. These gates ARE the comparability contract — they are identical
# for every runtime and must not be tuned per-gateway. See README "The SLO".
#
#   <loadgen summary json>  | eval_slo.py <sessions>
#
# Prints one line:
#   <sessions> PASS|FAIL|INVALID <reason> | partials=.. err=.. newest p50/p95 ...
#     ... correctness_err=<n>/<m>verified[,<k>dropped]   (n>0 fails the point)
# Exits 0 always (the driver brackets on the printed verdict, not exit code).
#
# Verdicts:
#   PASS     every gate holds AND the evidence is complete.
#   FAIL     the gateway missed a gate, judged on complete evidence.
#   INVALID  the measurement itself can't be trusted (missing/truncated/
#            malformed summary, a session task that panicked, incomplete value
#            verification on an otherwise passing point, or loadgen send lag).
#            Never a result: the driver re-runs it and never counts it as a
#            pass or a fail.
import json
import math
import sys

# Harness lag: latency is measured from each frame's scheduled send time, so
# loadgen lag is charged to the gateway one-for-one, and a lagging loadgen
# also changes the traffic the gateway sees (late sends arrive in bursts). The
# fixed loadgen stays at <= 4 ms p99 up to 8000 sessions; the 128 KiB
# read-buffer loadgen reached 31-54 ms where it was CPU-bound. Lag explained by
# the gateway not reading (send_block) is the gateway's, not the harness's.
HARNESS_LAG_P99_MAX_MS = 10.0
SEND_BLOCK_P99_MAX_MS = 5.0
LATENCY_GATES = ("newest_p50", "newest_p95", "oldest_p50", "oldest_p95")

# Fields a summary must carry to be judged at all. A loadgen that predates any
# of them can't produce a verdict (INVALID), rather than having them default
# to zero and pass.
REQUIRED = {
    "sessions": (),
    "partials": (),
    "protocol_errors": (),
    "inference_errors": (),
    "correctness_errors": (),
    "verified_partials": (),
    "verify_dropped": (),
    "harness_faults": (),
    "harness_lag_samples": (),
    "timeouts": ("connect", "send", "close", "session"),
    "newest_frame_to_partial_latency": ("p50_ms", "p95_ms"),
    "oldest_frame_to_partial_latency": ("p50_ms", "p95_ms"),
    "flush_lateness": ("p95_ms",),
    "harness_lag": ("p50_ms", "p99_ms", "p999_ms"),
    "send_block": ("p99_ms",),
}


def _number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v >= 0


def malformed(summary, sessions):
    """Why this summary can't be judged, or None.

    >>> good = {k: ({f: 1.0 for f in fs} if fs else 1) for k, fs in REQUIRED.items()}
    >>> malformed(good, "1") is None
    True
    >>> malformed({**good, "verify_dropped": None}, "1")
    'malformed-summary(verify_dropped)'
    >>> malformed({**good, "harness_lag": {"p50_ms": 1.0, "p99_ms": float("nan"),
    ...                                    "p999_ms": 1.0}}, "1")
    'malformed-summary(harness_lag.p99_ms)'
    >>> malformed(good, "2")
    'sessions-mismatch(summary=1,requested=2)'
    >>> malformed({**good, "partials": 5, "harness_lag_samples": 0}, "1")
    'no-harness-lag-samples'
    """
    for key, fields in REQUIRED.items():
        v = summary.get(key)
        if not fields:
            if not _number(v):
                return f"malformed-summary({key})"
            continue
        if not isinstance(v, dict):
            return f"malformed-summary({key})"
        for f in fields:
            if not _number(v.get(f)):
                return f"malformed-summary({key}.{f})"
    if sessions.isdigit() and summary["sessions"] != int(sessions):
        return f"sessions-mismatch(summary={summary['sessions']},requested={sessions})"
    if summary["partials"] > 0 and summary["harness_lag_samples"] == 0:
        return "no-harness-lag-samples"
    return None


def harness_invalid(summary, gates):
    """Why the loadgen, not the gateway, may be responsible for this point.

    Applies to a PASS too: a lagging loadgen sends a different workload. A
    FAIL on errors or correctness stands, since those were observed.

    >>> lag = lambda p99, block: {"harness_lag": {"p99_ms": p99}, "send_block": {"p99_ms": block}}
    >>> harness_invalid(lag(31.0, 0.0), ["newest_p50=222>200"])
    'harness_lag_p99=31.0>10'
    >>> harness_invalid(lag(31.0, 0.0), [])
    'harness_lag_p99=31.0>10'
    >>> harness_invalid(lag(3.0, 0.0), ["newest_p50=222>200"]) is None
    True
    >>> harness_invalid(lag(31.0, 40.0), ["newest_p50=222>200"]) is None  # back-pressure
    True
    >>> harness_invalid(lag(31.0, 0.0), ["newest_p50=222>200", "correctness_errors=3"]) is None
    True
    """
    if not all(g.split("=")[0] in LATENCY_GATES for g in gates):
        return None
    lag = summary["harness_lag"]["p99_ms"]
    if lag > HARNESS_LAG_P99_MAX_MS and summary["send_block"]["p99_ms"] < SEND_BLOCK_P99_MAX_MS:
        return f"harness_lag_p99={lag:.1f}>{HARNESS_LAG_P99_MAX_MS:g}"
    return None


def verification_incomplete(summary):
    """A PASS needs every measured partial's values recomputed.

    >>> verification_incomplete({"partials": 10, "verified_partials": 10, "verify_dropped": 0})
    >>> verification_incomplete({"partials": 10, "verified_partials": 7, "verify_dropped": 3})
    'verification-incomplete(7/10verified,3dropped)'
    >>> verification_incomplete({"partials": 10, "verified_partials": 5, "verify_dropped": 0})
    'verification-incomplete(5/10verified,0dropped)'
    """
    p, v, dropped = summary["partials"], summary["verified_partials"], summary["verify_dropped"]
    if dropped > 0 or v != p:
        return f"verification-incomplete({v}/{p}verified,{dropped}dropped)"
    return None


def count_errors(summary):
    """Distinct failures: failed sessions + gateway error frames.

    The loadgen bumps `protocol_errors` once for EVERY failed session, timeouts
    included, and additionally bumps one `timeouts.*` counter when the cause was
    a timeout (loadgen/rust/src/main.rs::record_session_outcome; unchanged since
    the initial commit). Timeouts are therefore a breakdown of a subset of
    `protocol_errors` and must not be added again. `max` only guards against a
    summary that violates that invariant (it never undercounts either way).
    `inference_errors` (error frames; the session keeps running) is disjoint.

    >>> count_errors({"protocol_errors": 2, "timeouts": {"connect": 2}})
    2
    >>> count_errors({"protocol_errors": 3, "inference_errors": 1,
    ...               "timeouts": {"send": 1, "close": 1}})
    4
    >>> count_errors({"protocol_errors": 0, "timeouts": {"session": 1}})
    1
    >>> count_errors({})
    0
    """
    t = summary.get("timeouts") or {}
    timeouts = sum(t.get(k, 0) for k in ("connect", "send", "close", "session"))
    return max(summary.get("protocol_errors", 0), timeouts) + summary.get(
        "inference_errors", 0
    )


def main():
    sess = sys.argv[1]
    raw = sys.stdin.read().strip()
    try:
        d = json.loads(raw)
        if not isinstance(d, dict):
            raise ValueError("summary is not a JSON object")
    except Exception as e:
        # No (or truncated) summary: the loadgen crashed, was OOM-killed or its
        # output was cut. Nothing was measured, so this is never a gateway FAIL.
        print(f"{sess} INVALID no-json ({e}); raw: {raw[:200]!r}")
        return
    bad = malformed(d, sess)
    if bad:
        print(f"{sess} INVALID {bad}")
        return
    if d["harness_faults"] > 0:
        print(f"{sess} INVALID harness_faults={d['harness_faults']} (session tasks panicked)")
        return

    p = d["partials"]
    nf = d["newest_frame_to_partial_latency"]
    of = d["oldest_frame_to_partial_latency"]
    errs = count_errors(d)
    erate = (errs / p) if p else 1.0
    # Correctness (continuity, expected stub values, malformed responses; see
    # loadgen/rust/src/verify.rs) IS a gate: a gateway that returns wrong,
    # dropped or misattributed results has no valid capacity number.
    cerr, cver, cdrop = d["correctness_errors"], d["verified_partials"], d["verify_dropped"]
    correctness = f"{cerr}/{cver}verified" + (f",{cdrop}dropped" if cdrop else "")
    hl = d["harness_lag"]
    lag = (
        f" harness_lag={hl['p50_ms']:.1f}/{hl['p99_ms']:.1f}/{hl['p999_ms']:.1f}"
        f" send_block_p99={d['send_block']['p99_ms']:.1f}"
    )
    gates = []
    if nf["p50_ms"] > 200:
        gates.append(f"newest_p50={nf['p50_ms']:.0f}>200")
    if nf["p95_ms"] > 350:
        gates.append(f"newest_p95={nf['p95_ms']:.0f}>350")
    if of["p50_ms"] > 1200:
        gates.append(f"oldest_p50={of['p50_ms']:.0f}>1200")
    if of["p95_ms"] > 1650:
        gates.append(f"oldest_p95={of['p95_ms']:.0f}>1650")
    if erate > 1e-5:
        gates.append(f"err_rate={erate:.2e}>1e-5 ({errs}/{p})")
    if p == 0:
        gates.append("zero-partials")
    if cerr > 0:
        gates.append(f"correctness_errors={cerr}")
    verdict = "PASS" if not gates else "FAIL"
    invalid = harness_invalid(d, gates)
    if verdict == "PASS" and not invalid:
        invalid = verification_incomplete(d)
    if invalid:
        verdict = "INVALID"
        gates = [invalid, *gates]
    print(
        f"{sess} {verdict} {';'.join(gates) if gates else 'ok'} | "
        f"partials={p} err={errs} "
        f"newest {nf['p50_ms']:.0f}/{nf['p95_ms']:.0f} "
        f"oldest {of['p50_ms']:.0f}/{of['p95_ms']:.0f} "
        f"flush_p95={d['flush_lateness']['p95_ms']:.2f} "
        f"correctness_err={correctness}"
        f"{lag}"
    )


if __name__ == "__main__":
    main()
