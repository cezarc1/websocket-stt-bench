#!/usr/bin/env python3
# Evaluate one loadgen summary JSON (stdin) against the websocket-stt-bench
# SLO gates. These gates ARE the comparability contract — they are identical
# for every runtime and must not be tuned per-gateway. See README "The SLO".
#
#   <loadgen summary json>  | eval_slo.py <sessions>
#
# Prints one line:
#   <sessions> PASS|FAIL <reason> | partials=.. err=.. newest p50/p95 ...
# Exits 0 always (the driver brackets on the printed verdict, not exit code).
import sys, json

sess = sys.argv[1]
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception as e:
    print(f"{sess} FAIL no-json ({e}); raw: {raw[:200]!r}")
    sys.exit(0)
p = d.get("partials", 0)
nf = d["newest_frame_to_partial_latency"]
of = d["oldest_frame_to_partial_latency"]
to = d.get("timeouts", {})
errs = (
    d.get("protocol_errors", 0)
    + d.get("inference_errors", 0)
    + to.get("connect", 0)
    + to.get("send", 0)
    + to.get("close", 0)
    + to.get("session", 0)
)
erate = (errs / p) if p else 1.0
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
verdict = "PASS" if not gates else "FAIL"
print(
    f"{sess} {verdict} {';'.join(gates) if gates else 'ok'} | "
    f"partials={p} err={errs} "
    f"newest {nf['p50_ms']:.0f}/{nf['p95_ms']:.0f} "
    f"oldest {of['p50_ms']:.0f}/{of['p95_ms']:.0f} "
    f"flush_p95={d['flush_lateness'].get('p95_ms', 0):.2f}"
)
