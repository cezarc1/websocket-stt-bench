# Stock OCaml / Async Benchmark Notes

## 2026-11-04 run9 (fixed loadgen; current README numbers)

Same node, pod shape, pinning, gateway images (`colocated-rerun`) and SLO as the 2026-11-02/03 runs below; the load generator is the fixed one (`loadgen:harness-7cf15e8`: 4 KiB WebSocket read buffer instead of tungstenite's 128 KiB, which it zero-filled on every read attempt; `TCP_NODELAY` on; harness-integrity verdicts). The old loadgen's own overhead was charged to the gateway as latency, so every earlier ceiling in this file is understated. One full pass: in-cluster conformance on all 13 gateways, then every 1-vCPU and 2-vCPU sweep (`scripts/bench/homelab/full-pass.sh`). At every passing point every partial was verified and loadgen send-lag p99 stayed ≤ 5 ms; every sweep was bounded by the gateway. Single pass, so read each ceiling as ±1 step. Raw logs: `results/homelab/run9-full/` (gitignored).

| Pass | vCPU | Confirmed | First solid fail | Borderline | Fail reason at first solid fail | Gateway cores at that fail |
|---|---:|---:|---:|---|---|---:|
| run9 | 1 | **2600** | 2700 | — | `newest_p50=202>200` | 1.00 |

Not re-measured at 2 vCPU in run9 (single Async domain; run6 measured 1.03×).

## 2026-11-02/03 homelab runs (co-located, pinned, correctness-verified)

One k3s node (i9-13900F); gateway pinned to P-cores 0,2 with a 1- or 2-vCPU quota and 4 GiB, loadgen on 4-11 (8 Tokio workers), inference on 12-15. Two independent full passes (run3, run4) after in-cluster conformance on the same images, plus targeted re-runs where listed (run5: C++ 2 vCPU; run6: OCaml 2 vCPU; run7: re-measured with the step-down sweep fix); the README reports the lowest confirmed value. "Confirmed" = every repeat passed (≥2/2) and the next step failed. Raw logs: `results/homelab/` (gitignored).

| Pass | vCPU | Confirmed | First solid fail | Borderline | Fail reason at first solid fail | Gateway cores at that fail |
|---|---:|---:|---:|---|---|---:|
| run3 | 1 | **1850** | 1900 | — | `newest_p50=223>200;oldest_p50=1204>1200` | 1.00 |
| run4 | 1 | **1800** | 1900 | 1850 (1/2 pass) | `newest_p50=218>200` | 1.00 |
| run6a | 2 | **1850** | 1900 | — | `newest_p50=221>200;oldest_p50=1201>1200` | 1.00 |
| run6b | 2 | **1850** | 1900 | — | `newest_p50=220>200;oldest_p50=1201>1200` | 1.00 |

Single Async domain: at 2 vCPU the gateway uses exactly 1.00 core at its first failing point, so 2 vCPU ≈ 1 vCPU.

## 2026-10-28 homelab re-run (split nodes, correctness-verified)

Split nodes: gateway + loadgen on node `cezar-4090`, one 6-CPU inference replica on node `2080` across the LAN; images tagged `gateway-fixes`. Every measured partial was verified client-side (exact stub values + per-session frame continuity) and `correctness_errors` was 0 on every point below. Same harness (`scripts/bench/run_point.sh`: 10 s warmup, 45 s measured, 30 s ramp, 1000 ms spread) and SLO; confirmed = 2/2 passes. Not directly comparable with the earlier single-node sections below, which are kept as history (see the README note).

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 1850 confirmed (2/2) ↔ 1900 first fail; 1875 borderline | CPU, single Async domain |
| 2 vCPU / 2 GiB | 1850 confirmed (2/2) ↔ 1900 first fail | no second-core lift |

Gateway fixes on this branch (shared with OxCaml Async): fragmented-message reassembly; RSV bits and bad 64-bit lengths close 1002; nothing is sent after our Close; faster teardown; a vanished-peer session leak fixed.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 |
|---:|---|---:|---:|
| 1 vCPU: 1850 | pass, confirmed (2/2) | 185 / 221-225 ms | 1166 / 1202-1207 ms |
| 1 vCPU: 1875 | borderline (2 pass / 1 fail on a single error) | 186-188 / 225-233 ms | 1167-1168 / 1206-1214 ms |
| 1 vCPU: 1900 | 1 pass / 1 fail, newest p50 | 200-210 / 246 ms | 1181-1190 / 1226-1227 ms |
| 2 vCPU: 1850 | pass, confirmed (2/2) | 185 / 218 ms | 1165 / 1199-1201 ms |
| 2 vCPU: 1900 | 1 pass / 1 fail, newest p50 | 198-202 / 240-243 ms | 1180-1183 / 1222-1225 ms |

## Summary (earlier single-node runs)

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 1930 confirmed | CPU, single Async domain |
| 2 vCPU | TBD | not yet rerun for the raw-transport build |

The stock OCaml gateway is the upstream OCaml comparison against the OxCaml build. After replacing the original `cohttp-async` + `websocket-async` stack with the same raw Async TCP / RFC 6455 transport class used by the OxCaml service, it reached 1930 confirmed sessions/vCPU.

## Implementation Shape

Application size: 850 LOC. Raw production size: 1220 LOC across 25 files.

The gateway uses stock OCaml 5.4.1, Jane Street Async, raw `Async.Tcp`, hand-rolled RFC 6455 framing plus SHA-1/base64, and HTTP/1.1 keep-alive to inference. It intentionally does not use OxCaml's mode system. The one-inflight invariant is structural: the per-session flush loop awaits inference before taking the next batch.

The README chart uses application LOC for cross-runtime fairness. For stock OCaml, that excludes 370 code-only lines of generic first-party transport/crypto shim (`Base64`, `Sha1`, `Http1`, `Websocket_frame`, `Websocket_handshake`) that package-backed runtimes get from dependencies. The raw production count still includes that shipped code. Comments and blank lines are not counted.

`WORKER_THREADS` and `INFERENCE_HTTP_CLIENTS` are env-contract no-ops for this service; the gateway remains one Async domain.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence. The raw-transport run on 2026-05-16 produced **1930 confirmed sessions/vCPU**, **1935 borderline**, and **1942 first solid fail**. The edge had zero protocol, inference, or timeout errors; the first solid failure was newest-frame p50 latency.

The old package-stack baseline reached 1212 confirmed sessions/vCPU. That result measured transport-library overhead more than stock OCaml itself and should not be reused as the current stock OCaml headline.

Raw stock OCaml 2-vCPU remains pending. Do not reuse the old `cohttp-async` / `websocket-async` 2-vCPU numbers for the raw-transport service.
