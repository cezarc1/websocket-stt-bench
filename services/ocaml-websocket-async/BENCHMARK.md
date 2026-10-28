# Stock OCaml / Async Benchmark Notes

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
