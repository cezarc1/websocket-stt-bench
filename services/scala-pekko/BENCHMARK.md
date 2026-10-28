# Scala / Pekko Benchmark Notes

## 2026-10-28 homelab re-run (split nodes, correctness-verified)

Split nodes: gateway + loadgen on node `cezar-4090`, one 6-CPU inference replica on node `2080` across the LAN; images tagged `gateway-fixes`. Every measured partial was verified client-side (exact stub values + per-session frame continuity) and `correctness_errors` was 0 on every point below. Same harness (`scripts/bench/run_point.sh`: 10 s warmup, 45 s measured, 30 s ramp, 1000 ms spread) and SLO; confirmed = 2/2 passes. Not directly comparable with the earlier single-node sections below, which are kept as history (see the README note).

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 600 confirmed (2/2) ↔ 650 (1 pass / 1 fail) | latency, then connect timeouts |
| 2 vCPU / 2 GiB | 1150 confirmed (2/2) ↔ 1200 first fail | latency, then connect timeouts |

Gateway fixes on this branch: real 1002/1003 close codes (Pekko's message API only sends 1000/1011; the fix relies on documented Pekko internals and fails loudly if they change); fragmented binary frames are collected in order; partials refused by a full queue are retried instead of dropped.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 |
|---:|---|---:|---:|
| 1 vCPU: 600 | pass, confirmed (2/2) | 192-193 / 275-278 ms | 1174 / 1257-1264 ms |
| 1 vCPU: 650 | 1 pass / 1 fail, newest p50 200 | 198-200 / 316-322 ms | 1179-1182 / 1294-1299 ms |
| 1 vCPU: 700 | fail, newest p50 + p95 | 217 / 479 ms | 1199 / 1434 ms |
| 1 vCPU: 850 | fail, latency + 73 connect timeouts | 344 / 738 ms | 1328 / 1701 ms |
| 2 vCPU: 1150 | pass, confirmed (2/2) | 193-196 / 310-321 ms | 1174-1177 / 1290-1322 ms |
| 2 vCPU: 1200 | fail, newest p50 + p95 | 205 / 398 ms | 1185 / 1378 ms |
| 2 vCPU: 1400 | fail, latency + 21 connect timeouts | 395 / 614 ms | 1378 / 1618 ms |

**A/B on 1 vCPU (why 1400 → 600).** At the earlier 4 GiB shape the fixed image fails 600 (latency), 900, 1200 and 1400 (latency + connect timeouts) — single repeats, no pod restarts or OOM. The `main` image at 900-1400 also fails on latency plus errors like the fixed image (connect timeouts at 1200/1400; at 900 its 142 errors were not timeouts). At 600 `main` fails on 283 errors with ~19k of ~27k partials: sessions closed 1003 on TCP-split frames (the old code rejects a 640-byte frame split across TCP reads; fixed on this branch). So the drop is not the code change and not memory; it is environmental (connect timeouts / latency under this setup), and the cause is not isolated. The fixed code is strictly more correct.

## Summary (earlier single-node runs)

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 4 GiB | 1400 | connect timeouts |
| 2 vCPU / 4 GiB | 2200 | connect timeouts |

Scala/Pekko underperformed expectations in this run. The first visible failure mode is connect timeouts rather than a clean latency-only CPU edge.

## Implementation Shape

Raw production size: 726 LOC. The gateway uses Scala 3.3 LTS and Apache Pekko's actor model.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU / 4 GiB**

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 1000 | pass | 181 / 200 ms | 1161 / 1181 ms | 7 / 52 ms |
| 1250 | pass | 195 / 213 ms | 1176 / 1193 ms | 10 / 65 ms |
| 1400 | pass | 199 / 224 ms | 1179 / 1267 ms | 18 / 74 ms |
| 1500 | fail, 314 connect timeouts | 196 / 217 ms | 1177 / 1198 ms | 16 / 74 ms |
| 1750 | fail, 176 connect timeouts | 208 / 315 ms | 1189 / 1294 ms | 31 / 86 ms |

**2 vCPU / 4 GiB**

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 2000 | pass | 153 / 196 ms | 1134 / 1179 ms | 9 / 38 ms |
| 2100 | pass | 184 / 200 ms | 1164 / 1181 ms | 10 / 60 ms |
| 2150 | pass | 188 / 204 ms | 1168 / 1184 ms | 10 / 45 ms |
| 2200 | pass | 190 / 206 ms | 1170 / 1186 ms | 13 / 62 ms |
| 2250 | fail, 50 connect timeouts | 161 / 213 ms | 1141 / 1193 ms | 12 / 43 ms |
| 2500 | fail, 399 connect timeouts | 157 / 211 ms | 1138 / 1192 ms | 11 / 42 ms |

## Gaps

The connect-timeout behavior is still a TODO. The benchmark currently reports the observed capacity instead of claiming a clean actor-model CPU ceiling.
