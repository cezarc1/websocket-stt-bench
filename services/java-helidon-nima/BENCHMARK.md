# Java / Helidon Níma Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 2625 upper bound | latency, then heap/OOM cliff |
| 2 vCPU / 2 GiB | 3750 upper bound | tail latency, then heap/OOM cliff |

Java is the strongest GC'd runtime in this benchmark. It stays in the Rust-adjacent band, but higher probes show heap pressure in the Helidon WebSocket read path under the 2 GiB pod limit.

## Implementation Shape

Raw production size: 917 LOC across 16 files.

The gateway uses Java 25 instance `void main()`, markdown doc comments, Helidon Níma virtual threads for receive/write/flush work, a one-slot `AtomicBoolean` inflight guard, sealed outbound messages, Jackson records for strict wire mapping, and a bounded four-slot outbox.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU / 2 GiB** — bracketed 2625 pass ↔ 2650 first fail. Artifacts were under `results/java-helidon-nima-1vcpu-2gib-probefix-20260511/`; analyzer input sanitized failed loadgen summaries to strip warning lines before final JSON.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 2500 | pass | 128 / 282 ms | 1116 / 1327 ms | 21 / 175 ms |
| 2550 | pass | 113 / 237 ms | 1095 / 1260 ms | 2.5 / 133 ms |
| 2600 | pass | 114 / 251 ms | 1097 / 1268 ms | 2.9 / 135 ms |
| 2625 | pass | 117 / 259 ms | 1101 / 1282 ms | 5.4 / 151 ms |
| 2650 | fail, latency | 300 / 4358 ms | 1332 / 6914 ms | 121 / 3049 ms |
| 2750 | fail, protocol errors + heap OOM | 1861 / 3533 ms | 4035 / 5599 ms | 462 / 2550 ms |
| 3000 | fail, protocol errors + heap OOM | 1437 / 4424 ms | 4776 / 5054 ms | 2636 / 2757 ms |

The 2650 point is the first balanced-SLO failure: no loadgen errors, but newest/oldest p50 and p95 all miss. Higher points fail as reliability/memory cliffs with `OutOfMemoryError: Java heap space` in the Helidon timer/listener path.

**2 vCPU / 2 GiB** — bracketed 3750 pass ↔ 3800 first fail. Artifacts were under `results/java-helidon-nima-2vcpu-2gib-20260511/`.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 3500 | pass | 107 / 185 ms | 1086 / 1179 ms | 0.18 / 75 ms |
| 3750 | pass | 110 / 204 ms | 1091 / 1208 ms | 0.31 / 92 ms |
| 3800 | fail, tail latency | 125 / 2316 ms | 1113 / 4010 ms | 8.6 / 1888 ms |
| 3825 | fail, send timeouts | 134 / 2648 ms | 1138 / 4026 ms | 16 / 1322 ms |
| 3900 | fail, send/close timeouts + heap OOM | 123 / 1620 ms | 1117 / 3219 ms | 5.8 / 862 ms |
| 4000 | fail, send timeouts + heap OOM | 5042 / 7213 ms | 7676 / 9994 ms | 1865 / 6169 ms |

Scale-up is useful but not linear: 2625 to 3750 is a 1.43X lift. The first 2-vCPU failure is tail latency at 3800; higher probes hit send timeout reliability and heap pressure.
