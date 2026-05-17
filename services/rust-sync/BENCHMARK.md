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

## C++ baseline caveat (why this is framed vs async Rust, not C++)

Verifying C++ on this exact harness/cluster showed the README's C++ 4450 is currently **not reproducible**: the C++ source did not build under Bazel 9.1.0 (native `py_binary` removed; dev-only `refresh_compile_commands` target — fixed here), and the only available C++ image (`sha-b2eed8f`) is pristine at 1000 sessions but **SIGSEGVs at ~2000** (a `WsSink` dangling-`uWS::WebSocket*` + reentrant-teardown use-after-free — also fixed here). On equal footing the only runnable C++ binary dies at 2000 while this gateway is confirmed to 3150 with zero errors. The harness itself is sound (C++ @1000 = identical clean baseline). The C++ fixes are committed but the rebuilt image can't be pushed from this branch (GHCR package-write perms), so a re-established C++ ceiling is a follow-up. This gateway is therefore compared to async Rust (3475, the credible same-harness comparator), not to the unverifiable C++ figure.

## Gaps

A single event loop is one core. 2-vCPU capacity should be measured by replica fan-out rather than in-pod scale-up.
