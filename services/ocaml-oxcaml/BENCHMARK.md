# OCaml / OxCaml Benchmark Notes

## Summary

| Shape | Result | Bottleneck |
|---|---:|---|
| 1 vCPU / 2 GiB | 2075 confirmed | CPU, single Async domain |
| one 2-vCPU pod | ~2125 | no second-core lift |
| two 1-vCPU replicas | 3350 confirmed | replica fan-out |

OxCaml reached the Go/Bun tier only after raw transport work: fresh inference connect per flush capped at 1050, persistent keep-alive moved it to 1750, and a zero-copy frame path moved it to 2075.

## Implementation Shape

Application size: 879 LOC. Raw production size: 1244 LOC across 21 files.

The gateway uses raw `Async.Tcp`, hand-rolled RFC 6455 framing plus SHA-1/base64, and HTTP/1.1 keep-alive to inference. The inflight invariant is represented as an opaque mint-once `Inflight_capability.t`, backed at runtime by an `Async.Mvar`.

The README chart uses application LOC for cross-runtime fairness. For OxCaml, that excludes 365 code-only lines of generic first-party transport/crypto shim (`Base64`, `Sha1`, `Http1`, `Websocket_frame`, `Websocket_handshake`) that package-backed runtimes get from dependencies. The raw production count still includes that shipped code. Comments and blank lines are not counted.

An attempted `@ unique` compile-time proof did not survive `Async`'s un-mode-annotated `Mvar`/`Deferred` boundary, so the shipped invariant is a type-shaped runtime guard, not a compiler proof. `janestreet/parallel` does not lift gateway capacity because its `parallel` requires an `@ once portable` closure and Async sockets are domain-pinned.

## Capacity Evidence

All k3s runs use 1000 ms flush cadence, 10 s warmup, 45 s measured, 30 s ramp, and 1000 ms session-start spread.

**1 vCPU / 2 GiB, tuned keep-alive + zero-copy** — bracketed 2075 confirmed ↔ 2100 borderline ↔ 2125 first solid fail. Artifacts were under `results/ocaml-oxcaml-1vcpu-2gib-20260516-tuned/`. The first solid failure is pure latency with zero protocol/inference/timeout errors.

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 | Flush lateness p50 / p95 |
|---:|---|---:|---:|---:|
| 1750 | pass | 115 / 154 ms | 1097 / 1132 ms | 0.89 / 2.69 ms |
| 2000 | pass | 183 / 211 ms | 1163 / 1192 ms | 1.93 / 3.49 ms |
| 2050 | pass | 183 / 211 ms | 1164 / 1192 ms | 1.89 / 3.45 ms |
| 2075 | pass, confirmed (4x) | 183 / 211 ms | 1163 / 1193 ms | 1.90 / 3.40 ms |
| 2100 | borderline (2 pass / 1 fail) | 189 / 229 ms | 1169 / 1209 ms | 1.89 / 3.41 ms |
| 2125 | fail, newest p50 | 214 / 247 ms | 1194 / 1229 ms | 1.89 / 3.55 ms |
| 2250 | fail, newest p50 + oldest p50 | 233 / 277 ms | 1214 / 1260 ms | 1.95 / 3.57 ms |
| 2500 | fail, latency collapse | 1147 / 1379 ms | 2130 / 2359 ms | 1.92 / 3.78 ms |
| 3000 | fail, collapse + 4% errors | 8618 / 10478 ms | 9478 / 11198 ms | 2.16 / 4.05 ms |

**Post-cleanup re-sweep** — after the epoch-fence, `Error_*` sum types, `Websocket_*`/`Http1` split, and silent-server timeout regression test, the 1-vCPU ladder reproduced the same edge: 2000 pass, 2075 pass, 2100 pass, 2125 first solid fail. Cleanup moved nothing measurable.

**2 vCPU, variant A: one 2-vCPU pod, single Async domain**

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 |
|---:|---|---:|---:|
| 2075 | pass | 183 / 211 ms | 1163 / 1192 ms |
| 2125 | pass | 187 / 223 ms | 1168 / 1206 ms |
| 2500 | fail, latency collapse | 923 / 1081 ms | 1902 / 2061 ms |

Ceiling is roughly 2125, within 1-vCPU node variance. The extra core sits idle because the gateway is one Async domain.

**2 vCPU, variant B: two 1-vCPU replicas behind the ClusterIP Service**

| Sessions | Result | Newest p50 / p95 | Oldest p50 / p95 |
|---:|---|---:|---:|
| 3000 | pass | 127 / 180 ms | 1108 / 1156 ms |
| 3200 | pass | 179 / 207 ms | 1159 / 1187 ms |
| 3350 | pass, confirmed ceiling | 192 / 239 ms | 1172 / 1220 ms |
| 3450 | fail, newest p50 | 216 / 278 ms | 1197 / 1257 ms |
| 3750 | fail, latency collapse | 644 / 838 ms | 1626 / 1817 ms |

Confirmed 3350 ↔ 3450, a 1.61X lift over single-pod 2075 with zero errors.
