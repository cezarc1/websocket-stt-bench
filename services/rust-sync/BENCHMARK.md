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

## C++ baseline (re-validated; why this is still framed vs async Rust)

Verifying C++ on this exact harness exposed two real defects in the C++ gateway, **both fixed and now re-validated**: (1) the source did not build under Bazel 9.1.0 (native `py_binary` removed; a dev-only `refresh_compile_commands` target made `bazel fetch //...` fail); (2) the only previously-available image (`sha-b2eed8f`) was pristine at 1000 sessions but **SIGSEGVed at ~2000** (a `WsSink` dangling-`uWS::WebSocket*` + reentrant-teardown use-after-free). With both fixed and the image rebuilt (`sha-567fb3a`), C++ was re-swept on this harness on 2026-05-17: **4350 confirmed (2/2) ↔ 4400 first solid fail (2/2)**, a clean newest-p50 latency edge, zero errors, **zero crashes across the entire 50→4450 campaign**. So the README's old "4450 confirmed" was measured on an unshippable crashing binary and is ~2% optimistic; the honest reproducible C++ ceiling is **4350** (the use-after-free fix costs ~2% steady-state via `shared_ptr` + virtual dispatch on the hot send path). The harness is sound (C++ @1000 = identical clean baseline). This gateway (3150) is still compared primarily to **async Rust (3475)** because that is the nearest comparator and the like-for-like language/transport contrast; C++'s validated 4350 remains above it and is the standing per-vCPU leader.

## Gaps

A single event loop is one core. 2-vCPU capacity should be measured by replica fan-out rather than in-pod scale-up.
