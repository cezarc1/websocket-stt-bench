# TypeScript / Bun Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 2550 upper bound | memory/error cliff |
| 2 vCPU / 2 GiB | n/a | not currently reported |

Bun-native TypeScript is surprisingly close to the Rust/JVM/Go tier, but this is a Bun-runtime measurement rather than h2c transport parity with Rust.

## Implementation Shape

Raw production size: 734 LOC across 6 files.

The gateway uses `Bun.serve()` WebSockets and Bun `fetch`, Valibot `strictObject` schemas at WebSocket and inference boundaries, a private `inflight` promise for the one-batch invariant, and a bounded four-slot outbox that treats Bun `send()` backpressure as occupied capacity.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU / 2 GiB** — bracketed 2550 pass ↔ 2600 first fail. Artifacts were under `results/typescript-bun-1vcpu-2gib-20260511/`; analyzer input sanitized failed loadgen summaries to strip warning lines before final JSON.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 2500 | pass | 101 / 133 ms | 1081 / 1114 ms | 0.7 / 7.8 ms |
| 2550 | pass | 103 / 148 ms | 1083 / 1142 ms | 0.8 / 29 ms |
| 2600 | fail, OOM/error cliff | 109 / 1271 ms | 1089 / 3916 ms | 1.9 / 1163 ms |
| 2625 | fail, 4126 inference errors | 108 / 1398 ms | 1088 / 3779 ms | 1.3 / 1277 ms |
| 2750 | OOMKilled / protocol fail | 1065 / 1134 ms | 5721 / 5760 ms | 1834 / 1861 ms |
| 3000 | OOMKilled / protocol fail | 0 / 0 ms | 0 / 0 ms | 0 / 0 ms |

The 2600 point failed the balanced realtime SLO on newest p95, oldest p95, and error rate. The paired 2625 run failed without a fresh restart, which keeps the result from being a pure memory-only story, but the first failing point still coincided with an OOMKilled gateway pod.

## Gaps

The natural follow-up is a second TypeScript variant with an explicit h2c-capable HTTP client. Bun `fetch` is the honest Bun-native client, but it is not equivalent to Rust's explicit h2c `reqwest` path.
