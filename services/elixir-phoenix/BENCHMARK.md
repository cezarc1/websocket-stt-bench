# Elixir / Phoenix Benchmark Notes

## Summary

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
