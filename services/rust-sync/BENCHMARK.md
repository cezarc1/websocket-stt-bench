# Rust / No-Async-Runtime Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 3150 confirmed | newest-p50 latency |
| 2 vCPU / 2 GiB | replica-only | single event loop |

This gateway uses no async runtime, but it is evented rather than thread-per-connection: one hand-rolled `mio`/epoll loop plus a bounded shared inference connection pool. It reaches the async-Rust tier at roughly 91% of Tokio/Axum's 3475 sessions/vCPU.

## Implementation Shape

Raw production size: 1111 LOC across 6 files.

The path to this result is the finding. A naive thread-per-connection baseline collapsed around 825 sessions/vCPU because hundreds of OS threads woke 50 times/sec on one CFS-quota'd core. Switching to a single event loop removed that freeze. The next wall was one inference socket per session, which created fd fan-out inside the same loop; a bounded shared inference pool fixed it.

The remaining gap to async Rust is attributed to hand-rolled `mio` + HTTP/1.1 versus Tokio's mature reactor and `reqwest` HTTP/2 multiplexing on the identical single-thread / 1-vCPU constraint.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU / 2 GiB** — 3150 confirmed ↔ 3300 first solid fail, clean newest-p50 latency edge with zero errors.

Detailed per-point tables are not currently checked in for this service; the root README records the confirmed bracket and interpretation.

## Gaps

A single event loop is one core. 2-vCPU capacity should be measured by replica fan-out rather than in-pod scale-up.
