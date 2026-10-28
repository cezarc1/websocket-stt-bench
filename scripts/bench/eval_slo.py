#!/usr/bin/env python3
# Evaluate one loadgen summary JSON (stdin) against the websocket-stt-bench
# SLO gates. These gates ARE the comparability contract — they are identical
# for every runtime and must not be tuned per-gateway. See README "The SLO".
#
#   <loadgen summary json>  | eval_slo.py <sessions>
#
# Prints one line:
#   <sessions> PASS|FAIL <reason> | partials=.. err=.. newest p50/p95 ...
#     ... correctness_err=<n>/<m>verified[,<k>dropped]   (n>0 fails the point)
# Exits 0 always (the driver brackets on the printed verdict, not exit code).
import json
import sys


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
    except Exception as e:
        print(f"{sess} FAIL no-json ({e}); raw: {raw[:200]!r}")
        return
    p = d.get("partials", 0)
    nf = d["newest_frame_to_partial_latency"]
    of = d["oldest_frame_to_partial_latency"]
    errs = count_errors(d)
    erate = (errs / p) if p else 1.0
    # Correctness (continuity + expected stub values, see loadgen/rust/src/verify.rs)
    # IS a gate: a gateway that returns wrong, dropped or misattributed results has
    # no valid capacity number. Summaries from loadgens that predate verification
    # lack the field and fail with "no-correctness-data". `verify_dropped` (values
    # the verifier thread couldn't keep up with) is reported, not gated; continuity
    # is still checked for those partials.
    cerr = d.get("correctness_errors")
    cver = d.get("verified_partials")
    cdrop = d.get("verify_dropped")
    correctness = (
        "n/a" if cerr is None else f"{cerr}/{cver if cver is not None else '?'}verified"
    )
    if cdrop:
        correctness += f",{cdrop}dropped"
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
    if cerr is None:
        gates.append("no-correctness-data")
    elif cerr > 0:
        gates.append(f"correctness_errors={cerr}")
    verdict = "PASS" if not gates else "FAIL"
    print(
        f"{sess} {verdict} {';'.join(gates) if gates else 'ok'} | "
        f"partials={p} err={errs} "
        f"newest {nf['p50_ms']:.0f}/{nf['p95_ms']:.0f} "
        f"oldest {of['p50_ms']:.0f}/{of['p95_ms']:.0f} "
        f"flush_p95={d['flush_lateness'].get('p95_ms', 0):.2f} "
        f"correctness_err={correctness}"
    )


if __name__ == "__main__":
    main()
