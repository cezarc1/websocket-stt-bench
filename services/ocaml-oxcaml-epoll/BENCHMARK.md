# oxcaml-epoll Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 2900 confirmed | newest-p50 latency around 3000 |
| 2 vCPU / 2 GiB | TBD | not measured |

`oxcaml-epoll` is a separate no-Async OxCaml variant. It keeps the same
WebSocket protocol, flush cadence, inference service, pod shape, and SLO gates
as the Async OxCaml implementation, but replaces Async with one Linux epoll
loop and explicit nonblocking WebSocket and HTTP/1.1 inference state machines.

The measured 1-vCPU bracket is now above Java's confirmed point: 2900 sessions
passed twice, while 3000 is borderline and failed once on newest-frame p50
latency. With the original 512-slot inference pool, the fixed image could still
emit rare gateway error frames near 2650. The diagnostic loadgen identified
those as local `inference_request` / `connection_reset` frames with message
`inference pool exhausted`. Widening the non-multiplexed HTTP/1.1 inference slot
pool to 1024 removed that error cliff; the remaining edge is latency, not
protocol or inference-status errors.

## Implementation Shape

Application size: 1680 LOC. Raw production size: 2126 LOC across 15 files.

The gateway uses Linux epoll through tiny C stubs, nonblocking accept/read/write,
a fixed 640-byte masked WebSocket frame fast path after `start`, a reusable
per-session PCM buffer, reusable outbound WebSocket buffers, reusable inference
request/response buffers, one timer heap for flush deadlines and inference
timeouts, and a fixed-size HTTP/1.1 keep-alive inference slot pool. It preserves
the benchmark invariant of at most one in-flight inference request per
connection.

The README chart uses application LOC for cross-runtime fairness. For
`oxcaml-epoll`, that excludes 446 code-only lines of generic first-party
transport/crypto shim (`Base64`, `Sha1`, HTTP helpers, WebSocket framing and
handshake, masking) that package-backed runtimes get from dependencies. The raw
production count still includes that shipped code. Comments and blank lines are
not counted.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp,
1000 ms session-start spread, one 1-vCPU gateway pod, four inference pods, and
the official SLO gates.

Gateway image measured:
`ghcr.io/cezarc1/websocket-stt-bench/ocaml-oxcaml-epoll:sha-f2e04e8`
(`sha256:5f6dcf21a60d1c1d27840714b1a85a458578573557e4c96b0756486dd9b771ea`).
That image includes the post-review correctness fixes: SIGPIPE ignored, invalid
64-bit WebSocket lengths rejected, stale inference-slot events guarded, readable
HUP drained before treating HUP as fatal, missing `Content-Length` responses
closing their inference socket, non-429 HTTP 4xx classified as `http_4xx`, and a
`Content-Length` prefix parser trap fixed.

The 1024-slot edge runs used diagnostic loadgen image
`ghcr.io/cezarc1/websocket-stt-bench/loadgen:sha-5b764c5`
(`sha256:e9d930fd709fa45ce70e26c0b9bfc3afe6eb5311b170858710a3d23a4b4f7dd0`),
which adds error-kind counters to the summary JSON without changing the SLO
gates, timings, pod shape, or protocol traffic.
Those accepted runs set `INFERENCE_HTTP_CLIENTS=1024` in the gateway
Deployment; the branch defaults now match that setting.

Current-tree local validation:

- `cargo test --locked -p stt-loadgen` passed.
- `just oxcaml-epoll-portable-test` passed.
- `just oxcaml-epoll-test` passed.
- `just oxcaml-epoll-check` passed.
- `just oxcaml-epoll-conformance` passed on 2026-07-05.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 | Errors |
|---:|---|---:|---:|---:|---:|
| 2650 | pass, confirmed (2x), 1024 slots | 111-113 / 173-183 ms | 1093-1094 / 1146-1154 ms | 0.59-0.69 / 10.35-11.73 ms | 0 |
| 2700 | pass, 1024 slots | 115 / 186 ms | 1097 / 1157 ms | 0.77 / 12.92 ms | 0 |
| 2750 | pass, 1024 slots | 111 / 174 ms | 1093 / 1146 ms | 0.59 / 9.62 ms | 0 |
| 2800 | pass, 1024 slots | 118 / 209 ms | 1101 / 1179 ms | 1.43 / 16.53 ms | 0 |
| 2850 | pass, 1024 slots | 127 / 220 ms | 1110 / 1191 ms | 1.54 / 18.85 ms | 0 |
| 2900 | pass, confirmed (2x), 1024 slots | 123-140 / 219-237 ms | 1107-1125 / 1189-1207 ms | 1.99-2.88 / 18.25-21.70 ms | 0 |
| 3000 | borderline, 1024 slots | 137 pass, 211 fail / 243-272 ms | 1124-1188 / 1209-1251 ms | 9.64-9.90 / 21.49-27.30 ms | 0 |

Artifacts for the confirmed and failed edge points:

- `results/oxcaml-onechange-20260705T002616Z/epoll-slots1024-r1-2900-2900.summary.json`
- `results/oxcaml-onechange-20260705T002833Z/epoll-slots1024-r2-2900-2900.summary.json`
- `results/oxcaml-onechange-20260705T003045Z/epoll-slots1024-r1-3000-3000.summary.json`
- `results/oxcaml-onechange-20260705T003302Z/epoll-slots1024-r2-3000-3000.summary.json`
- `results/oxcaml-onechange-20260705T000915Z/epoll-f2e04e8-diag-r3-2650-2650.summary.json`

## Notes

The 512-slot fixed-image diagnostic run at 2650 failed with 89 inference error
frames, all `inference_request` / `connection_reset` with message `inference
pool exhausted`. That made the first accepted optimization after the corrected
image an env/config change, not a parser or GC change: raise
`INFERENCE_HTTP_CLIENTS` from 512 to 1024 for the epoll variant.

After the slot-pool change, the 3000-session failure had zero protocol errors,
zero inference errors, and zero loadgen timeouts; it failed only
`newest_p50=211>200`. The next bottleneck to investigate is therefore gateway
latency under CPU pressure, not inference response parsing or HTTP status
handling.
