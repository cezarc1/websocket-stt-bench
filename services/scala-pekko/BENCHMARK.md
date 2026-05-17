# Scala / Pekko Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 4 GiB | 1400 | connect timeouts |
| 2 vCPU / 4 GiB | 2200 | connect timeouts |

Scala/Pekko underperformed expectations in this run. The first visible failure mode is connect timeouts rather than a clean latency-only CPU edge.

## Implementation Shape

Raw production size: 726 LOC. The gateway uses Scala 3.3 LTS and Apache Pekko's actor model.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU / 4 GiB**

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 1000 | pass | 181 / 200 ms | 1161 / 1181 ms | 7 / 52 ms |
| 1250 | pass | 195 / 213 ms | 1176 / 1193 ms | 10 / 65 ms |
| 1400 | pass | 199 / 224 ms | 1179 / 1267 ms | 18 / 74 ms |
| 1500 | fail, 314 connect timeouts | 196 / 217 ms | 1177 / 1198 ms | 16 / 74 ms |
| 1750 | fail, 176 connect timeouts | 208 / 315 ms | 1189 / 1294 ms | 31 / 86 ms |

**2 vCPU / 4 GiB**

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 2000 | pass | 153 / 196 ms | 1134 / 1179 ms | 9 / 38 ms |
| 2100 | pass | 184 / 200 ms | 1164 / 1181 ms | 10 / 60 ms |
| 2150 | pass | 188 / 204 ms | 1168 / 1184 ms | 10 / 45 ms |
| 2200 | pass | 190 / 206 ms | 1170 / 1186 ms | 13 / 62 ms |
| 2250 | fail, 50 connect timeouts | 161 / 213 ms | 1141 / 1193 ms | 12 / 43 ms |
| 2500 | fail, 399 connect timeouts | 157 / 211 ms | 1138 / 1192 ms | 11 / 42 ms |

## Gaps

The connect-timeout behavior is still a TODO. The benchmark currently reports the observed capacity instead of claiming a clean actor-model CPU ceiling.
