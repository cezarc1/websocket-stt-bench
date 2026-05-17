# C++23 / uWebSockets Benchmark Notes

## Summary

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

2-vCPU capacity is still unmeasured. uWebSockets is loop-per-thread, so 2-vCPU should scale in-pod (2 worker loops) as well as by replica fan-out — both worth measuring honestly.
