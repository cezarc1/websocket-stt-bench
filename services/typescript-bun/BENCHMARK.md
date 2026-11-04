# TypeScript / Bun Benchmark Notes

## 2026-11-04 run9 (fixed loadgen; current README numbers)

Same node, pod shape, pinning, gateway images (`colocated-rerun`) and SLO as the 2026-11-02/03 runs below; the load generator is the fixed one (`loadgen:harness-7cf15e8`: 4 KiB WebSocket read buffer instead of tungstenite's 128 KiB, which it zero-filled on every read attempt; `TCP_NODELAY` on; harness-integrity verdicts). The old loadgen's own overhead was charged to the gateway as latency, so every earlier ceiling in this file is understated. One full pass: in-cluster conformance on all 13 gateways, then every 1-vCPU and 2-vCPU sweep (`scripts/bench/homelab/full-pass.sh`). At every passing point every partial was verified and loadgen send-lag p99 stayed ≤ 5 ms; every sweep was bounded by the gateway. Single pass, so read each ceiling as ±1 step. Raw logs: `results/homelab/run9-full/` (gitignored).

| Pass | vCPU | Confirmed | First solid fail | Borderline | Fail reason at first solid fail | Gateway cores at that fail |
|---|---:|---:|---:|---|---|---:|
| run9 | 1 | **3400** | 3600 | 3500 (1/2 pass) | `newest_p95=1796>350;oldest_p95=3054>1650;err_rate=2.51e-01>1e-5 (21172/84246)` | 0.92 |

Passing points use about 0.8 of the core; above 3400 Bun collapses (at 3600: 21,172 errors). Under that overload the loadgen also caught correctness errors — partials with wrong or misattributed values (36 at 3700, 1,795 at 3900) — which earlier runs did not gate on. Not measured at 2 vCPU (single event loop).

## 2026-11-02/03 homelab runs (co-located, pinned, correctness-verified)

One k3s node (i9-13900F); gateway pinned to P-cores 0,2 with a 1- or 2-vCPU quota and 4 GiB, loadgen on 4-11 (8 Tokio workers), inference on 12-15. Two independent full passes (run3, run4) after in-cluster conformance on the same images, plus targeted re-runs where listed (run5: C++ 2 vCPU; run6: OCaml 2 vCPU; run7: re-measured with the step-down sweep fix); the README reports the lowest confirmed value. "Confirmed" = every repeat passed (≥2/2) and the next step failed. Raw logs: `results/homelab/` (gitignored).

| Pass | vCPU | Confirmed | First solid fail | Borderline | Fail reason at first solid fail | Gateway cores at that fail |
|---|---:|---:|---:|---|---|---:|
| run3 | 1 | **2750** | 2800 | — | `err_rate=1.37e-02>1e-5` | 0.88 |
| run4 | 1 | **2750** | 2800 | — | `newest_p95=1538>350;oldest_p95=3670>1650;err_rate=1.25e-02>1e-5` | 0.87 |

Not CPU-bound: the gateway uses about 0.8 of its core. At 2800-2900 sessions Bun's `fetch` client starts timing out on inference requests (run3 at 2900: 12,843 timeouts and 1,163 connection resets while inference sat at 0.41 cores, unthrottled); the 1,085 correctness errors there are all `missing_tail` (a session's final frames never reported after those failures), not wrong values. 2 vCPU not measured. Pinned vs unpinned at 2750: 2/2 pass pinned, 2/2 collapse unpinned.

## 2026-10-28 homelab re-run (split nodes, correctness-verified)

Split nodes: gateway + loadgen on node `cezar-4090`, one 6-CPU inference replica on node `2080` across the LAN; images tagged `gateway-fixes`. Every measured partial was verified client-side (exact stub values + per-session frame continuity) and `correctness_errors` was 0 on every point below. Same harness (`scripts/bench/run_point.sh`: 10 s warmup, 45 s measured, 30 s ramp, 1000 ms spread) and SLO; confirmed = 2/2 passes. Not directly comparable with the earlier single-node sections below, which are kept as history (see the README note).

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 2400 confirmed (2/2) ↔ 2500 (1 pass / 1 fail) | inference connection-reset errors, then error cliff |
| 2 vCPU / 2 GiB | n/a | not measured |

Gateway fixes on this branch: close 1011 when Bun drops an outbound message (was a silent stop); `maxPayloadLength` 8 KiB → 128 KiB so oversized frames reach the 1003 path.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 |
|---:|---|---:|---:|
| 2400 | pass, confirmed (2/2) | 102 / 135-145 ms | 1082 / 1118-1137 ms |
| 2500 | 1 pass / 1 fail (17 inference connection resets) | 103-105 / 148-174 ms | 1082-1084 / 1138-1179 ms |
| 2600 | fail, every session errored + 4626 inference error frames | 114 / 1357 ms | 1093 / 3295 ms |

## Summary (earlier single-node runs)

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
