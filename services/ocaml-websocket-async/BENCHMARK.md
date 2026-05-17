# Stock OCaml / Async Benchmark Notes

## Summary

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
