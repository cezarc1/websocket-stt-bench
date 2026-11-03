# Elixir / Phoenix Benchmark Notes

## 2026-11-02/03 homelab runs (co-located, pinned, correctness-verified)

One k3s node (i9-13900F); gateway pinned to P-cores 0,2 with a 1- or 2-vCPU quota and 4 GiB, loadgen on 4-11 (8 Tokio workers), inference on 12-15. Two independent full passes (run3, run4) after in-cluster conformance on the same images, plus targeted re-runs where listed (run5: C++ 2 vCPU; run6: OCaml 2 vCPU; run7: re-measured with the step-down sweep fix); the README reports the lowest confirmed value. "Confirmed" = every repeat passed (≥2/2) and the next step failed. Raw logs: `results/homelab/` (gitignored).

| Pass | vCPU | Confirmed | First solid fail | Borderline | Fail reason at first solid fail | Gateway cores at that fail |
|---|---:|---:|---:|---|---|---:|
| run3 | 1 | **1250** | 1300 | — | `newest_p50=237>200;oldest_p50=1218>1200;err_rate=1.38e-04>1e-5` | 1.00 |
| run4 | 1 | **1250** | 1300 | — | `newest_p50=210>200` | 0.99 |
| run3 | 2 | **2200** | 2300 | — | `newest_p50=241>200;newest_p95=374>350;oldest_p50=1222>1200;err_rate=3.33e-04>1e-5` | 2.00 |
| run4 | 2 | **2100** | 2400 | 2300 (1/2 pass) | `newest_p50=288>200;newest_p95=483>350;oldest_p50=1269>1200` | 2.00 |
| run7a | 2 | **2200** | 2300 | — | `newest_p50=259>200;newest_p95=409>350;oldest_p50=1240>1200` | 2.00 |
| run7b | 2 | **2200** | 2300 | — | `newest_p50=240>200;newest_p95=366>350;oldest_p50=1221>1200` | 2.00 |

## 2026-10-28 homelab re-run (split nodes, correctness-verified)

Split nodes: gateway + loadgen on node `cezar-4090`, one 6-CPU inference replica on node `2080` across the LAN; images tagged `gateway-fixes`. Every measured partial was verified client-side (exact stub values + per-session frame continuity) and `correctness_errors` was 0 on every point below. Same harness (`scripts/bench/run_point.sh`: 10 s warmup, 45 s measured, 30 s ramp, 1000 ms spread) and SLO; confirmed = 2/2 passes. Not directly comparable with the earlier single-node sections below, which are kept as history (see the README note).

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 1250 confirmed (2/2) ↔ 1300 first fail | connect timeouts |
| 2 vCPU / 2 GiB | 2100 confirmed (2/2) ↔ 2200 (1 pass / 1 fail) | connect timeouts |

Gateway fixes on this branch: a crashed inference task no longer wedges the session with `busy?` stuck, and a non-object JSON inference body becomes a `parse_error` frame.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 |
|---:|---|---:|---:|
| 1 vCPU: 1250 | pass, confirmed (2/2) | 107 / 157-170 ms | 1087 / 1136-1149 ms |
| 1 vCPU: 1300 | fail, 167 errors (154 connect timeouts) | 104 / 148 ms | 1084 / 1127 ms |
| 1 vCPU: 1325 | fail, every session errored + 195 inference errors (Finch `request_timeout`) | 172 / 850 ms | 1154 / 3092 ms |
| 2 vCPU: 2100 | pass, confirmed (2/2) | 105-106 / 155-167 ms | 1086 / 1136-1145 ms |
| 2 vCPU: 2200 | 1 pass / 1 fail (347 errors, 332 connect timeouts) | 105-110 / 146-224 ms | 1085-1092 / 1126-1201 ms |
| 2 vCPU: 2300 | fail, every session errored + 745 inference errors (Finch `request_timeout`) | 380 / 1055 ms | 1380 / 2447 ms |

## Summary (earlier single-node runs)

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU | 1250 confirmed | memory/CPU |
| 2 vCPU | 2250 confirmed | CPU |

Elixir has a modest 1-vCPU ceiling but the cleanest vertical scale-up here: 1.80X from 1 to 2 vCPU.

## Implementation Shape

Raw production size: 784 LOC across 13 files.

Channels would force binary frames through a JSON-base64 wrapper at 50 fps, so the gateway uses `WebSockAdapter.upgrade/4` directly on Phoenix + Bandit. Pattern matching at function heads enforces the protocol: text-only `start`, binary-only PCM after start, strict 640-byte frames, and WebSocket close codes 1002/1003 for invalid protocol states. Process-per-connection gives isolation and supervision; the `busy?` flag represents the one-inflight invariant.

Rough edge: production observability is still thin; there are no per-connection metrics or buffer-depth histograms yet.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU** — memory-shaped, 1250 confirmed bound.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 1250 | pass | 109 / 149 ms | 1090 / 1128 ms | 0.7 / 3.4 ms |
| 1375 @ 1Gi | OOMKilled / protocol fail | 0 / 0 ms | 0 / 0 ms | 0 / 0 ms |
| 1375 @ 2Gi | latency + error fail, 18 inference errors | 207 / 689 ms | 1188 / 1697 ms | 4.7 / 13 ms |
| 1450 @ 2Gi | OOMKilled, 899 inference errors | 333 / 2658 ms | 1359 / 6357 ms | 12 / 29 ms |

**2 vCPU** — 2250 confirmed upper point, 2300 fails with inference errors.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 2200 | pass | 110 / 154 ms | 1091 / 1134 ms | 0.6 / 4.1 ms |
| 2250 | pass, rerun | 117 / 196 ms | 1099 / 1174 ms | 1.0 / 6.7 ms |
| 2300 | fail, 66 inference errors | 357 / 1196 ms | 1370 / 2507 ms | 5.2 / 21 ms |
