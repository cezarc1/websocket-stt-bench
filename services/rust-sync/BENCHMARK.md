# Rust / No-Async-Runtime Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 4400 confirmed (2/2) ↔ 4600 first solid fail (2/2) | newest-p50 latency |
| 2 vCPU / 2 GiB | 5500 confirmed (2/2) ↔ 5600 first solid fail (2/2) | newest-p50 latency (WS loop is the heavy thread) |

No async runtime. The gateway is **two OS threads, each its own `mio`/epoll loop**: a WebSocket loop (thread A) and a dedicated inference loop (thread B), connected by `std::sync::mpsc` + a `mio::Waker`. This is the structural mirror of the C++23 gateway (uWebSockets loop + a libcurl `std::jthread`). **At 1 vCPU it beats validated C++ (4400 vs 4350, same harness/SLO/cluster)** and is ~27% above async Rust/Axum (3475), on plain HTTP/1.1, with zero external dependencies beyond `mio`/`tungstenite`/`serde`.

## Implementation Shape

Raw production size: 1221 LOC across 6 files (the +110 over the prior single-loop revision is almost entirely the thread/channel/waker plumbing in `inference.rs`).

The path to this result is the finding, in three evidence-driven stages on the identical 1-vCPU / 2-GiB constraint:

1. **Thread-per-connection blocking I/O collapsed at ~825.** Hundreds of OS threads each waking ~50×/s on one CFS-quota'd core throttle-froze the quota (`cpu.stat nr_throttled` 8%→66% over 800→875). The per-connection work was trivial; the scheduler was the wall.
2. **A single hand-rolled `mio`/epoll loop reached 3150.** Removing the freeze exposed the next wall: one inference socket per session created fd fan-out *inside the one loop*. A bounded shared inference connection pool fixed that and got to 3150 (~91% of async Rust).
3. **Splitting inference onto its own OS thread reached 4400 — past C++.** The residual 3150→3475 gap to async Rust was assumed to be hand-rolled `mio` + HTTP/1.1 vs Tokio + `reqwest` HTTP/2. **That assumption was wrong.** The real ceiling was *cooperative single-loop contention*: inference connect/send/recv/JSON-parse interleaved with WebSocket flushes on one thread, so any inference burst delayed every connection's flush. Moving inference to a second thread — same HTTP/1.1, same pool, same `serde_json`, no async runtime — lets the kernel preempt the two halves independently and lifted the confirmed ceiling from 3150 to 4400, **above validated C++ (4350)**. The transport (HTTP/1.1 vs HTTP/2) was never the gap; the architecture was.

The one-inflight-per-connection invariant stays structural on thread A's per-`Conn` `pending` gate; thread B owns the pool and slot lifecycle. `compute_poll_timeout` follows the proven C++ design (10 ms park while requests are in flight, 1000 ms when idle — the Rust equivalent of uWebSockets' `kActivePollTimeoutMs` + `queue_cv_.wait_for(1000ms)`).

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, 1000 ms session-start spread; harness/SLO `scripts/bench/{run_point,eval_slo}`, identical for every runtime. Isolated single-tenant node. Measured 2026-05-17 on image `sha-1485d85`. Zero protocol errors and zero restarts across the entire campaign (50→7000).

**1 vCPU / 2 GiB — 4400 confirmed (2/2) ↔ 4600 first solid fail (2/2)**, a clean newest-p50 latency edge.

| Sessions | Result | Newest p50 / p95 |
|---:|---|---:|
| 3300 | pass | 149 / 197 ms |
| 3500 | pass | 153 / 207 ms |
| 4000 | pass | 182 / 252 ms |
| 4300 | pass | 188 / 282 ms |
| 4400 | pass (2/2) | 195 / 194 p50 |
| 4500 | borderline | 198 pass / 200 fail |
| 4600 | fail (2/2) | 206 / 210 p50 |
| 4700 | fail | 220 / 324 ms |

**2 vCPU / 2 GiB — 5500 confirmed (2/2) ↔ 5600 first solid fail (2/2).**

| Sessions | Result | Newest p50 / p95 |
|---:|---|---:|
| 4400 | pass | 182 / 236 ms |
| 5000 | pass | 187 / 279 ms |
| 5500 | pass (2/2) | 195 / 196 p50 |
| 5600 | fail (2/2) | 200 / 203 p50 |
| 5750 | fail | 211 / 301 ms |
| 6000 | fail | 211 / 299 ms |

## vs the other runtimes (same harness)

- **vs the single-loop rust-sync baseline (3150 / replica-only):** +40% at 1 vCPU, and the 2-vCPU story flips entirely — the single loop was one core (zero in-pod lift, replica-only); two threads give genuine in-pod scaling.
- **vs async Rust / Axum (3475 @1, 4250 @2):** +27% at 1 vCPU, +29% at 2 vCPU.
- **vs validated C++ / uWebSockets (4350 confirmed @1):** **rust-sync 4400 confirmed beats it.** Narrow (~1.1%) but reproducible on the same harness — and note the symmetry: C++'s own *first solid fail* was 4400, exactly where rust-sync is still confirmed (2/2). At 1221 LOC vs C++'s 1551, rust-sync now **strictly Pareto-dominates C++**: more capacity, less code. C++ 2-vCPU remains unmeasured; rust-sync's 5500 is the highest 2-vCPU figure in the suite.

## Gaps

2-vCPU in-pod lift is ~1.25× (5500/4400), not ~2×, because the two threads are asymmetric: the WebSocket loop (tungstenite framing + `serde_json` + epoll over thousands of sockets) is the heavy thread and becomes the single-core bottleneck once inference has its own core. Pushing 2-vCPU further would require sharding the WebSocket loop across cores (loop-per-core + `SO_REUSEPORT`), which is a different architecture (closer to C++ `WORKER_THREADS>1` or Axum multi-worker) and out of scope for the canonical no-async-runtime experiment. Replica fan-out is the other 2-vCPU lever and is not separately swept.
