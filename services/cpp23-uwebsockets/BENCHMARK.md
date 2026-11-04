# C++23 / uWebSockets Benchmark Notes

## 2026-11-04 run9 (fixed loadgen; current README numbers)

Same node, pod shape, pinning, gateway images (`colocated-rerun`) and SLO as the 2026-11-02/03 runs below; the load generator is the fixed one (`loadgen:harness-7cf15e8`: 4 KiB WebSocket read buffer instead of tungstenite's 128 KiB, which it zero-filled on every read attempt; `TCP_NODELAY` on; harness-integrity verdicts). The old loadgen's own overhead was charged to the gateway as latency, so every earlier ceiling in this file is understated. One full pass: in-cluster conformance on all 13 gateways, then every 1-vCPU and 2-vCPU sweep (`scripts/bench/homelab/full-pass.sh`). At every passing point every partial was verified and loadgen send-lag p99 stayed ≤ 5 ms; every sweep was bounded by the gateway. Single pass, so read each ceiling as ±1 step. Raw logs: `results/homelab/run9-full/` (gitignored).

| Pass | vCPU | Confirmed | First solid fail | Borderline | Fail reason at first solid fail | Gateway cores at that fail |
|---|---:|---:|---:|---|---|---:|
| run9 | 1 | **8300** | 8400 | — | `newest_p50=237>200;oldest_p50=1217>1200;err_rate=1.85e-05>1e-5 (7/378976)` | 1.00 |
| run9 | 2 | **9000** | 9200 | 9100 (1/2 pass) | `err_rate=4.75e-05>1e-5 (19/399708)` | 1.70 |

At 2 vCPU the edge fails on the error budget, not latency: every error is the gateway's inference request timing out (`Timeout was reached`), while the gateway uses about 1.75 of its 2 cores with no throttling and newest p50/p95 stay near 117/150 ms. Inference was at about 1.6 cores on its 4 logical CPUs (12-15, two physical P-cores), above anything measured before, so this ceiling may be set by the shared inference path rather than by C++; it was not isolated. At the failing 9100/9200 points the loadgen's verifier also dropped 13-17k partials (those points fail on observed errors either way; the passing 9000 and 9100 runs were fully verified). Above about 7500 sessions the loadgen's send-lag p999 is 45-62 ms (p99 ≤ 5 ms).

## 2026-11-02/03 homelab runs (co-located, pinned, correctness-verified)

One k3s node (i9-13900F); gateway pinned to P-cores 0,2 with a 1- or 2-vCPU quota and 4 GiB, loadgen on 4-11 (8 Tokio workers), inference on 12-15. Two independent full passes (run3, run4) after in-cluster conformance on the same images, plus targeted re-runs where listed (run5: C++ 2 vCPU; run6: OCaml 2 vCPU; run7: re-measured with the step-down sweep fix); the README reports the lowest confirmed value. "Confirmed" = every repeat passed (≥2/2) and the next step failed. Raw logs: `results/homelab/` (gitignored).

| Pass | vCPU | Confirmed | First solid fail | Borderline | Fail reason at first solid fail | Gateway cores at that fail |
|---|---:|---:|---:|---|---|---:|
| run3 | 1 | **3800** | 4300 | 4200 (1/2 pass) | `newest_p50=205>200` | 1.00 |
| run4 | 1 | **3800** | 4300 | 4200 (1/2 pass) | `newest_p50=206>200` | 1.00 |
| run7a | 1 | **4100** | 4200 | — | `newest_p50=201>200` | 1.00 |
| run7b | 1 | **4100** | 4200 | — | `newest_p50=201>200` | 1.00 |
| run3 | 2 | **6300** | 6450 | 6400 (1/2 pass) | `newest_p50=201>200` | 1.99 |
| run4 | 2 | **5900** | 6000 | — | `newest_p95=677>350;oldest_p95=2595>1650;err_rate=2.88e-05>1e-5` | 1.94 |
| run5a | 2 | **5900** | 6000 | — | `newest_p50=217>200;newest_p95=359>350` | 1.78 |
| run5b | 2 | **5700** | 6750 | 6300 (1/2 pass), 6600 (1/2 pass), 6700 (1/2 pass) | `newest_p50=205>200` | 1.95 |
| run7c | 2 | **5800** | 5900 | 6300 (1/2 pass) | `newest_p50=215>200;newest_p95=382>350;err_rate=1.50e-04>1e-5` | 1.93 |

2 vCPU is not stable to one step: newest p50 sits at about 200 ms (192-231 across sweeps) from 5850 to 6750 sessions, so the 200 ms gate flips on noise; occasional burst failures (gateway memory to 2-2.9 GiB plus error frames) also depress the next points because the sweep does not restart the gateway between points. The README shows the lowest confirmed value. The 1-vCPU passes and one 2-vCPU re-run pre-date a sweep fix (after a failed confirm the sweep jumped back to an older passing probe instead of stepping down one step); run7 re-measured them with the fix.

## 2026-10-28 homelab re-run (split nodes, correctness-verified)

Split nodes: gateway + loadgen on node `cezar-4090`, one 6-CPU inference replica on node `2080` across the LAN; images tagged `gateway-fixes`. Every measured partial was verified client-side (exact stub values + per-session frame continuity) and `correctness_errors` was 0 on every point below. Same harness (`scripts/bench/run_point.sh`: 10 s warmup, 45 s measured, 30 s ramp, 1000 ms spread) and SLO; confirmed = 2/2 passes. Not directly comparable with the earlier single-node sections below, which are kept as history (see the README note).

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 3000 confirmed (4/4) ↔ 3300 first solid fail (2/2); 3100-3200 borderline | newest-p50 latency |
| 2 vCPU / 2 GiB | 5900 confirmed (2/2) ↔ 6000 fail | at the inference server's measured knee — lower bound |

Gateway fixes on this branch: removed the 150-frame cap that overwrote the oldest buffered frame, and raised `maxPayloadLength` from 16 KiB to 1 MiB so oversized frames get close 1003 instead of a dropped TCP connection.

**1 vCPU / 2 GiB**

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 |
|---:|---|---:|---:|
| 3000 | pass, confirmed (4/4) | 159-175 / 230-236 ms | 1138-1155 / 1210-1222 ms |
| 3100 | borderline (3 pass / 1 fail, newest p50 202) | 182-202 / 245-281 ms | 1162-1181 / 1233-1278 ms |
| 3200 | borderline (4 pass / 1 fail, newest p50 219) | 193-219 / 260-306 ms | 1172-1198 / 1247-1293 ms |
| 3250 | fail (single repeat), newest + oldest p50 | 221 / 306 ms | 1201 / 1295 ms |
| 3300 | fail (2/2), newest p50 | 204-216 / 275-297 ms | 1183-1195 / 1261-1288 ms |

**2 vCPU / 2 GiB** — the single inference replica was clean at 6000 rps and saturating at 7000 rps (open-loop `stt-inferbench`), so 5900 sessions (~5900 req/s) is at the inference knee and may be inference-limited.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 |
|---:|---|---:|---:|
| 5900 | pass, confirmed (2/2) | 193-195 / 267-268 ms | 1166-1167 / 1247 ms |
| 6000 | fail, newest p50 | 202 / 272 ms | 1174 / 1252 ms |

**A/B on 1 vCPU (why 4350 → 3000).** The previously published image `sha-567fb3a` on the same split setup passes 3000 (2/2) and fails 3200, 3500 and 4000 (2/2 each), so the code changes are not the cause; one of its 4000 repeats also had 4000 `continuity_gap` correctness errors, consistent with the 150-frame cap fixed on this branch. The fixed image with inference co-located on the gateway node passes 3000, 3500 and 4000 and fails 4350 (single repeats). The split setup therefore costs C++ about 20% (co-located passed up to 4000 vs 3000-3200 split, single repeats). A plausible but untested mechanism is the LAN hop latency plus the libcurl HTTP/2 client thread sharing the 1-vCPU quota.

## Summary (earlier single-node runs)

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 4350 confirmed (2/2) ↔ 4400 first solid fail (2/2) | newest-p50 latency |
| 2 vCPU / 2 GiB | TBD | not yet measured |

C++23 is the current per-vCPU leader. The tuned run uses uWebSockets plus system libcurl with HTTP/2 support and `INFERENCE_HTTP_CLIENTS=128`.

## Implementation Shape

Raw production size: 1551 LOC across 11 files.

The gateway uses uWebSockets' loop-per-thread model, Glaze for strict JSON, a bounded per-session buffer, and system libcurl with nghttp2 for gateway-to-inference HTTP/2. The earlier BCR curl build did not provide the needed HTTP/2 behavior and hit a much lower cliff.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread. SLO gates and harness are `scripts/bench/{run_point,eval_slo}` — identical for every runtime.

**1 vCPU / 2 GiB (re-validated 2026-05-17 on the crash-fixed image `sha-567fb3a`)** — bracketed **4350 confirmed (2/2 pass) ↔ 4400 first solid fail (2/2 fail)**. A clean newest-p50 latency edge, zero protocol errors, **zero crashes/restarts across the entire 50→4450 campaign**.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p95 | Restarts |
|---:|---|---:|---:|---:|---:|
| 50 | pass | 103 / 139 ms | 1083 / 1120 ms | 0.96 ms | 0 |
| 2000 | pass | 99 / 126 ms | 1079 / 1107 ms | 1.00 ms | 0 |
| 3200 | pass | 124 / 170 ms | 1104 / 1149 ms | 20.88 ms | 0 |
| 3800 | pass | 166 / 220 ms | 1146 / 1205 ms | 48.48 ms | 0 |
| 4100 | pass | 191 / 253 ms | 1171 / 1243 ms | 65.41 ms | 0 |
| 4250 | pass | 191 / 259 ms | 1172 / 1248 ms | 70.72 ms | 0 |
| 4350 | pass (1/2) | 196 / 263 ms | 1177 / 1254 ms | 72.89 ms | 0 |
| 4350 | pass (2/2) | 197 / 264 ms | 1179 / 1256 ms | 73.09 ms | 0 |
| 4400 | fail, newest p50 (1/2) | 202 / 268 ms | 1183 / 1261 ms | 75.39 ms | 0 |
| 4400 | fail, newest p50 (2/2) | 203 / 271 ms | 1184 / 1265 ms | 77.12 ms | 0 |
| 4450 | fail, newest p50 | 208 / 274 ms | 1188 / 1270 ms | 77.50 ms | 0 |

### Why this differs from the earlier "4450 ↔ 4475"

The pre-fix figure (4450 pass ↔ 4475 first fail) was measured on image `sha-b2eed8f`, which **SIGSEGVs under load** (use-after-free: `WsSink` held a raw `uWS::WebSocket*` whose `closed_` guard was only set in explicit `close_with()`, so uWS-initiated auto-closes left a dangling pointer that a deferred libcurl completion dereferenced; compounded by `behavior.close` destroying the `Session` re-entrantly mid-method). On this harness that binary is pristine at 1000 sessions but crash-loops (exit 139, CrashLoopBackOff) at ~2000 — so the original 4450 was never a reproducible or shippable number.

The fix (`OutboundSink::mark_closed()` + `Session` owning the sink by `shared_ptr` + deferred teardown via the loop scheduler) trades ~2% steady-state capacity for correctness: the sink is now reached through a `shared_ptr` + virtual dispatch on the hot `send()` path, and close does an extra scheduler hop. The crash-fixed binary's honest reproducible ceiling is **4350**, ~2.2% below the unshippable 4450. The build was also broken under Bazel 9.1.0 (native `py_binary` removed; the dev-only `refresh_compile_commands` target made `bazel fetch //...` fail) — also fixed, so C++ now builds from source and the image is reproducible.

## Gaps

2-vCPU capacity was unmeasured in these single-node runs (the 2026-10-28 split-node re-run above measured 5900, at the inference knee). uWebSockets is loop-per-thread, so 2-vCPU should scale in-pod (2 worker loops) as well as by replica fan-out — both worth measuring honestly.
