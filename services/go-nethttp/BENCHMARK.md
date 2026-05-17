# Go / net-http Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 2500 upper bound | CPU/latency |
| 2 vCPU / 2 GiB | 4000 upper bound | CPU/latency |

Go lands in the Rust-adjacent operational tier: mature standard server stack, explicit h2c inference transport, and simple horizontal deployment.

## Implementation Shape

Raw production size: 893 LOC across 6 files.

The gateway uses `net/http`, `coder/websocket`, a one-token channel for the inflight invariant, `goccy/go-json` with strict decoding at WebSocket and inference boundaries, and an explicit h2c inference client built on `golang.org/x/net/http2`. The implementation is a little larger because the session core is split for unit testing instead of hiding protocol behavior inside the HTTP handler.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU / 2 GiB** — bracketed 2500 pass ↔ 2600 first fail. Artifacts were under `results/go-nethttp-1vcpu-2gib-20260511/`.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 2000 | pass | 119 / 160 ms | 1099 / 1141 ms | 0.008 / 0.723 ms |
| 2500 | pass | 161 / 240 ms | 1143 / 1215 ms | 0.010 / 3.959 ms |
| 2600 | fail, newest + oldest p50 | 262 / 443 ms | 1246 / 1439 ms | 0.011 / 5.467 ms |
| 2650 | fail, latency | 344 / 721 ms | 1324 / 1730 ms | 0.012 / 7.499 ms |
| 2700 | fail, latency | 350 / 811 ms | 1335 / 1877 ms | 0.012 / 8.719 ms |
| 2750 | fail, 20 inference errors | 348 / 846 ms | 1337 / 1927 ms | 0.012 / 8.887 ms |
| 3000 | fail, 703 inference errors | 538 / 1254 ms | 1554 / 2601 ms | 0.012 / 6.395 ms |

The 2750 and 3000 points later fail on inference timeouts, but the balanced realtime SLO first fails at 2600 on newest p50/p95 and oldest p50.

**2 vCPU / 2 GiB** — bracketed 4000 pass ↔ 4050 first fail. Artifacts were under `results/go-nethttp-2vcpu-2gib-20260511/`.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 3500 | pass | 120 / 160 ms | 1099 / 1145 ms | 0.009 / 0.684 ms |
| 4000 | pass | 190 / 317 ms | 1176 / 1275 ms | 0.012 / 3.151 ms |
| 4050 | fail, newest p50 | 203 / 342 ms | 1190 / 1307 ms | 0.012 / 3.897 ms |
| 4100 | fail, newest + oldest p50 | 222 / 376 ms | 1209 / 1355 ms | 0.013 / 4.603 ms |
| 4250 | fail, latency | 333 / 571 ms | 1305 / 1561 ms | 0.014 / 5.775 ms |
