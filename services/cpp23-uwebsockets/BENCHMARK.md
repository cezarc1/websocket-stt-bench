# C++23 / uWebSockets Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 4450 confirmed | CPU/latency |
| 2 vCPU / 2 GiB | TBD | not yet measured |

C++23 is the current per-vCPU leader. The tuned run uses uWebSockets plus system libcurl with HTTP/2 support and `INFERENCE_HTTP_CLIENTS=128`.

## Implementation Shape

Raw production size: 1551 LOC across 11 files.

The gateway uses uWebSockets' loop-per-thread model, Glaze for strict JSON, a bounded per-session buffer, and system libcurl with nghttp2 for gateway-to-inference HTTP/2. The earlier BCR curl build did not provide the needed HTTP/2 behavior and hit a much lower cliff.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU / 2 GiB** — bracketed 4450 pass ↔ 4475 first fail.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 3000 | pass | 116 / 160 ms | 1097 / 1140 ms | 35 / 75 ms |
| 3500 | pass | 155 / 204 ms | 1136 / 1188 ms | 35 / 76 ms |
| 4000 | pass | 176 / 240 ms | 1156 / 1225 ms | 35 / 77 ms |
| 4250 | pass | 190 / 255 ms | 1171 / 1246 ms | 35 / 76 ms |
| 4375 | pass | 195 / 260 ms | 1176 / 1253 ms | 35 / 76 ms |
| 4450 | pass | 199 / 272 ms | 1180 / 1262 ms | 35 / 76 ms |
| 4475 | fail, newest p50 | 204 / 270 ms | 1186 / 1264 ms | 35 / 76 ms |
| 4500 | fail, newest p50 | 215 / 278 ms | 1196 / 1274 ms | 35 / 76 ms |

## Gaps

2-vCPU capacity is still unmeasured.
