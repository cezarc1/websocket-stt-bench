# oxcaml-epoll Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 2625 confirmed on pre-review-fix image | inference error frames at the cliff |
| 2 vCPU / 2 GiB | TBD | not measured |

`oxcaml-epoll` is a separate no-Async OxCaml variant. It keeps the same
WebSocket protocol, flush cadence, inference service, pod shape, and SLO gates
as the Async OxCaml implementation, but replaces Async with one Linux epoll
loop and explicit nonblocking WebSocket and HTTP/1.1 inference state machines.

The measured 1-vCPU bracket matches Java's confirmed point: 2625 sessions
passed twice, while 2650 failed twice on the error budget. Those k3s runs used
the pre-review-fix image listed below. Re-run the current branch image before
treating 2625 as the branch's final capacity claim. The 2650 failures were not
latency collapses: newest-frame p95 stayed below 200 ms, with zero protocol
errors and zero loadgen timeouts. The failures were gateway-emitted inference
error frames.

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

Image measured:
`ghcr.io/cezarc1/websocket-stt-bench/ocaml-oxcaml-epoll:sha-4cd2c96`
(`sha256:91bdb355c7a102a09eb558c82b3b7c4afbf18dff1442e83188f8ce7959af25ed`).
Later post-review correctness fixes ignore SIGPIPE, reject invalid 64-bit
WebSocket lengths, guard stale inference-slot events, and drain readable
inference responses before treating HUP as fatal. A second review pass also
made missing `Content-Length` responses close their inference socket, classified
non-429 HTTP 4xx responses as `http_4xx`, and fixed a `Content-Length` header
prefix parser trap. Re-measure 2625 and 2650 before making a final capacity
claim for the fixed code.

Current-tree local validation:

- `just oxcaml-epoll-portable-test` passed.
- `just oxcaml-epoll-test` passed.
- `just oxcaml-epoll-conformance` passed on 2026-07-04.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 | Errors |
|---:|---|---:|---:|---:|---:|
| 2200 | pass | 104 / 150 ms | 1084 / 1126 ms | 0.17 / 2.43 ms | 0 |
| 2400 | pass | 108 / 154 ms | 1089 / 1130 ms | 0.39 / 5.94 ms | 0 |
| 2500 | pass | 110 / 162 ms | 1092 / 1139 ms | 0.51 / 8.19 ms | 0 |
| 2600 | pass | 110 / 163 ms | 1091 / 1138 ms | 0.50 / 8.70 ms | 0 |
| 2625 | pass, confirmed (2x) | 110-111 / 161-171 ms | 1091-1093 / 1136-1144 ms | 0.50-0.58 / 7.41-9.97 ms | 0 |
| 2650 | fail, error budget (2x) | 113-117 / 187-193 ms | 1094-1099 / 1157-1165 ms | 0.68-0.99 / 12.00-14.44 ms | 37, 190 |

Artifacts for the confirmed and failed edge points:

- `results/oxcaml-onechange-20260704T210248Z/epoll-4cd2c96-r1-2625.summary.json`
- `results/oxcaml-onechange-20260704T210727Z/epoll-4cd2c96-r2-2625.summary.json`
- `results/oxcaml-onechange-20260704T210505Z/epoll-4cd2c96-r1-2650.summary.json`
- `results/oxcaml-onechange-20260704T210948Z/epoll-4cd2c96-r2-2650.summary.json`

## Notes

The 2650 failure mode needs narrower instrumentation before making a stronger
claim about the exact branch. Loadgen counts `inference_errors` when it receives
a gateway `ServerMessage::Error`; the current preserved artifacts include the
aggregate count, not the warning log lines with the exact `kind` and `message`.
The next diagnostic run should record error-kind counters for pool exhaustion,
connection reset, HTTP status, parse error, and inference timeout, and should
check whether the readable-HUP slot fix changes the 2650 error cliff.
