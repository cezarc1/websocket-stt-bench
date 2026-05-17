# Rust / Axum Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU | 3475 confirmed | CPU / newest p95 |
| 2 vCPU | 4250 confirmed | CPU / latency |

Async Rust is the best balance in this benchmark: 696 raw production LOC and 3475 sessions/vCPU.

## Implementation Shape

Raw production size: 696 LOC across 6 files.

The gateway uses Tokio + Axum, `Arc<Semaphore>::new(1)` for the one-inflight invariant, `BytesMut` for zero-copy frame batching, and biased `tokio::select!` to drain partials before reading new frames so backpressure surfaces as oldest-frame latency growth. Serde `deny_unknown_fields` validates the wire protocol.

Rough edges noted in the main review: `Mutex.lock().expect(...)` panics on poisoning, gateway-local tests are still sparse, and runtime version constants are manually kept in sync with `Cargo.toml`.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU** — confirmed ceiling 3475. The tuned run uses `INFERENCE_HTTP_CLIENTS=512` plus direct flush-loop inference. 3485 and 3500 each produced one clean pass but failed confirmation on newest p95, so they are not headline numbers.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 3000 | pass | 122 / 188 ms | 1105 / 1171 ms | 53 / 187 ms |
| 3250 | pass | 188 / 342 ms | 1174 / 1336 ms | 210 / 589 ms |
| 3300 | pass | 186 / 342 ms | 1171 / 1333 ms | 195 / 565 ms |
| 3350 | pass | 184 / 336 ms | 1169 / 1330 ms | 204 / 565 ms |
| 3400 | pass | 177 / 331 ms | 1163 / 1328 ms | 208 / 613 ms |
| 3450 | pass, confirmed | 178 / 348 ms | 1168 / 1352 ms | 263 / 737 ms |
| 3475 | pass, confirmed | 167 / 317 ms | 1155 / 1317 ms | 223 / 618 ms |
| 3485 | borderline, confirm failed newest p95 | 185 / 362 ms | 1177 / 1367 ms | 282 / 769 ms |
| 3500 | borderline, confirm failed newest p95 | 192 / 385 ms | 1186 / 1391 ms | 300 / 794 ms |
| 3510 | fail, newest p95 | 183 / 358 ms | 1175 / 1362 ms | 271 / 732 ms |
| 3525 | fail, newest p95 | 186 / 370 ms | 1178 / 1374 ms | 288 / 773 ms |
| 3550 | fail, newest p50+p95, 2 inference errors | 202 / 413 ms | 1197 / 1421 ms | 314 / 883 ms |
| 3600 | fail, newest p50+p95 | 205 / 420 ms | 1200 / 1428 ms | 353 / 923 ms |

**2 vCPU** — bound 4250. 4375 is borderline; latest rerun crossed newest p50 by 1.9 ms. 5000 collapses.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 4000 | pass | 114 / 185 ms | 1097 / 1163 ms | 45 / 131 ms |
| 4250 | pass | 166 / 262 ms | 1150 / 1246 ms | 116 / 293 ms |
| 4375 | borderline | 202 / 346 ms | 1187 / 1332 ms | 163 / 401 ms |
| 4500 | latency fail | 294 / 593 ms | 1279 / 1579 ms | 176 / 446 ms |
| 5000 | fail, 9 inference errors | 1037 / 1648 ms | 2521 / 3473 ms | 269 / 653 ms |
