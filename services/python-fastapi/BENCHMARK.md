# Python / FastAPI Benchmark Notes

## 2026-10-28 homelab re-run (split nodes, correctness-verified)

Split nodes: gateway + loadgen on node `cezar-4090`, one 6-CPU inference replica on node `2080` across the LAN; images tagged `gateway-fixes`. Every measured partial was verified client-side (exact stub values + per-session frame continuity) and `correctness_errors` was 0 on every point below. Same harness (`scripts/bench/run_point.sh`: 10 s warmup, 45 s measured, 30 s ramp, 1000 ms spread) and SLO; confirmed = 2/2 passes. Not directly comparable with the earlier single-node sections below, which are kept as history (see the README note).

| Runtime shape | 1 vCPU | 2 vCPU | Bottleneck |
|---|---:|---:|---|
| CPython 3.14.4 + uvloop + FastAPI / Granian | 1150 (2/2) ↔ 1200 | 1500 (2/2) ↔ 1550 | CPU / newest-p50 latency |
| CPython 3.14.4t free-threaded | 175 (2/2) ↔ 200 | 200 (2/2) ↔ 225 | send/close timeout reliability |

Shapes: 1 vCPU / 2 GiB with `WORKER_THREADS=1` / `GRANIAN_LOOPS=1`; 2 vCPU / 2 GiB with `WORKER_THREADS=2` / `GRANIAN_LOOPS=2`. Whether this 2-vCPU shape differs from the earlier 1750 "two worker processes" run, and explains the GIL drop to 1500, was not isolated.

Gateway fixes on this branch: a binary-first message or a text message after `start` now closes 1002 (previously closed without a code); a `{}` start is rejected; a quiet disconnect before `start` is handled.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 |
|---:|---|---:|---:|
| GIL 1 vCPU: 1150 | pass, confirmed (2/2) | 195-196 / 241-248 ms | 1176-1177 / 1226-1232 ms |
| GIL 1 vCPU: 1200 | fail, newest p50 | 214 / 271 ms | 1195 / 1257 ms |
| GIL 2 vCPU: 1500 | pass, confirmed (2/2) | 193-197 / 280-287 ms | 1172-1177 / 1264-1271 ms |
| GIL 2 vCPU: 1550 | fail, newest p50/p95 + oldest p50 | 228 / 369 ms | 1205 / 1343 ms |
| FT 1 vCPU: 50 | fail, 2 errors (1 send + 1 close timeout) | 102 / 132 ms | 1083 / 1113 ms |
| FT 1 vCPU: 175 | pass, confirmed (2/2) | 100-101 / 128-129 ms | 1080-1081 / 1109 ms |
| FT 1 vCPU: 200 | fail, 1 send timeout | 102 / 132 ms | 1082 / 1113 ms |
| FT 2 vCPU: 200 | pass, confirmed (2/2) | 100 / 128-130 ms | 1080-1081 / 1109-1110 ms |
| FT 2 vCPU: 225 | fail, 3 errors (2 send + 1 close timeout) | 102 / 131 ms | 1082 / 1112 ms |

Free-threaded failures are still sporadic send/close timeouts at ~100 ms latency, even at 50 sessions, so its "ceiling" is a reliability figure, not a capacity edge.

## Summary (earlier single-node runs)

| Runtime shape | 1 vCPU | 2 vCPU | Bottleneck |
|---|---:|---:|---|
| CPython 3.14.4 + uvloop + FastAPI / Granian | 1100 | 1750 | CPU/latency |
| CPython 3.14.4t free-threaded + uvloop + FastAPI / Granian | 180 | 205 | send/close timeout reliability |

The GIL-on stack is the leanest async implementation and punches above expectations. The free-threaded `mt` stack is reliability-limited in this combination and should not be treated as a verdict on no-GIL Python.

## Implementation Shape

Raw production size: 678 LOC across 9 files.

Boundary safety is Pydantic with `extra="forbid"` plus `ty` static checking. The flush loop and writer loop are separate long-running tasks, keeping inference time independent of WebSocket send time. GIL-on and free-threaded builds share one codebase via a startup runtime assertion.

Rough edge: the inflight invariant is a runtime task guard rather than a type-enforced primitive.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**CPython 3.14.4, 1 vCPU** — CPU/latency-bound, roughly 400 MiB at the edge.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 1000 | pass | 177 / 214 ms | 1157 / 1196 ms | 9 / 44 ms |
| 1100 @ 2Gi | pass, rerun | 199 / 237 ms | 1180 / 1224 ms | 11 / 46 ms |
| 1150 @ 2Gi | latency fail | 205 / 248 ms | 1186 / 1235 ms | 9 / 37 ms |
| 1200 | latency fail | 235 / 280 ms | 1214 / 1265 ms | 9 / 37 ms |

**CPython 3.14.4, 2 vCPU / 2 worker processes** — process-level scale-out; gateway CPU-bound at the edge.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 1500 | pass, rerun | 163 / 204 ms | 1144 / 1185 ms | 5 / 40 ms |
| 1750 | pass, edge | 197 / 258 ms | 1177 / 1246 ms | 11 / 47 ms |
| 1775 | latency fail | 422 / 666 ms | 1403 / 1647 ms | 8 / 41 ms |
| 1800 | latency fail | 828 / 1452 ms | 1773 / 2431 ms | 8 / 41 ms |
| 2000 | collapse | 2077 / 6771 ms | 2966 / 7639 ms | 12 / 44 ms |

**CPython 3.14.4t free-threaded `mt`, 1 vCPU** — reliability-limited before latency.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 180 | pass, rerun | 99 / 127 ms | 1079 / 1107 ms | 0.3 / 1.0 ms |
| 190 | fail, 1 send + 1 close timeout | 99 / 128 ms | 1079 / 1109 ms | 0.3 / 1.0 ms |
| 195 | fail, 2 send timeouts | 102 / 132 ms | 1082 / 1112 ms | 0.3 / 0.9 ms |
| 200 | fail, 2 send + 1 close timeout | 99 / 127 ms | 1079 / 1108 ms | 0.5 / 1.0 ms |

**CPython 3.14.4t free-threaded `mt`, 2 vCPU** — same shape, marginal lift.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 200 | pass | 99 / 127 ms | 1079 / 1107 ms | 0.5 / 1.0 ms |
| 205 | pass | 99 / 126 ms | 1079 / 1107 ms | 0.4 / 1.0 ms |
| 210 | fail, 3 send timeouts | 102 / 132 ms | 1082 / 1113 ms | 0.4 / 1.0 ms |
| 215 | fail, 1 send + 1 close timeout | 98 / 127 ms | 1079 / 1108 ms | 0.4 / 1.0 ms |
| 225 | fail, 1 send + 1 close timeout | 102 / 133 ms | 1082 / 1114 ms | 0.4 / 1.0 ms |

## Interpretation

The `mt` failure mode is not latency: newest p50 sits near 99 ms up to the failing point. Failures are send/close timeouts, likely stack/runtime interaction in Granian/FastAPI/Starlette rather than the interpreter alone.
