# Harness spec: record during the run, judge after it

Status: draft rev 2 (2026-11-03). Rev 2 folds in an independent review and the verdict-integrity patch (§11 step 0). Scope: the load generator (`loadgen/rust`), the point runner (`scripts/bench/run_point.sh`), the SLO evaluator (`scripts/bench/eval_slo.py`), the sweep driver (`scripts/bench/homelab/`), the inference simulator's latency source and conformance admission. Gateways, the wire protocol and the SLO thresholds are out of scope.

**Purpose.** The harness has to be trustworthy enough to hill-climb each implementation toward expert level. A measured difference between two builds must be attributable to the builds, with a stated uncertainty, not to the loadgen, the placement or the search.

## 1. Principles

1. **The loadgen records; it never judges.** During a run it only speaks the protocol and appends timestamped raw events to memory. No verification, windowing, histograms or JSON parsing in the session loop.
2. **One offline evaluator is the only judge.** Every verdict is a pure function of `(run artifacts, evaluator version, SLO config)`. Changing a gate means re-evaluating, not re-running.
3. **A harness fault is never a gateway FAIL**, and missing evidence is never a PASS. Either one makes the point INVALID, and the search never counts an INVALID point as a pass or a fail.
4. **All offered work is accounted for.** Every planned session and every measured frame ends in exactly one recorded outcome: answered (with a latency), answered with an error frame, or never answered.
5. **Artifacts are durable and complete before anyone reads them.** Written once, sealed by manifests, tied to executed image digests. Logs are for humans only, never a data channel.
6. **The harness's own error is measured, not assumed**, at every session count where a number is published (§8).

## 2. Defects in the current pipeline

How a verdict is reached today: session tasks check continuity inline and hand stub verification to one thread → an aggregator builds HDR histograms and an optional CSV → the summary JSON is scraped from the pod log → `eval_slo.py` gates the percentiles → `sweep.py` brackets on the printed verdict → the README takes the lowest confirmed value across passes by hand.

Status: **fixed** = by the verdict-integrity patch (§11 step 0); **open** = addressed by this spec.

| # | Defect | Where | Effect | Status |
|---|---|---|---|---|
| D1 | The samples CSV is written inside the loadgen container with no volume; the Job is then deleted | `run_point.sh` | 556 summaries and zero sample CSVs under `results/homelab` | open (§6) |
| D2 | The summary is scraped from `kubectl logs` (`head -c 200000`); the loadgen exit status was swallowed (`\|\| true`) | `run_point.sh` | A crash, OOM or truncation became `FAIL no-json`, charged to the gateway | **fixed** (exit status, deadline and kill are INVALID; no-json is INVALID). Log scraping itself is open (§6). |
| D3 | Stub verification drops jobs when its queue is full; a drop was printed, not gated | `submit_verify`, `eval_slo.py` | PASS with 323k of 630k partials unchecked (`harness-ceiling2`) | **fixed** (a PASS needs `verified == partials`, `dropped == 0`); open: move verification offline (§5) |
| D4 | The CSV omits the stub values; error frames, out-of-window responses, actual send times and failure causes are not recorded per event | `write_sample_csv_row`, `run_session` | Nothing can be re-verified or re-judged | open (§4) |
| D5 | The error-rate numerator covers the whole run; the denominator covers only measured partials. One failed session and one failed batch each count as 1 | `count_errors` | Undefined window; whether admission is reliable depends on throughput and run length | open (§5.4) |
| D6 | Responses processed after `end_at` skip latency and verification; closing starts as soon as sending ends; the 300-frame (6 s) missing-tail tolerance applies to measured audio | `process_inbound`, `verify.rs` | **False PASS is possible at a passing point:** a gateway that goes silent for its last ~4 s stays under the tolerance with healthy observed latency | open (§5.2) |
| D7 | `harness_lag` covers only send lateness; the receive timestamp is taken after JSON decode; INVALID attribution uses two aggregate p99s | `run_session`, `eval_slo.py` | Receive-side delay is charged to the gateway; aggregate p99s can't tell cause from effect | open (§5.5, §8.4) |
| D8 | A point that was INVALID twice became a FAIL | `sweep.py` | A harness-capped point set the ceiling (reproduced with a mocked sweep) | **fixed** (§7) |
| D9 | Loadgen `imagePullPolicy: IfNotPresent` with mutable tags; no executed digest recorded for any image | `run_point.sh`, chart | Conformance and measurement aren't tied to the same binaries | open (§6) |
| D10 | No tracked mutation suite or calibration artifacts; the calibration claim covers relative newest p50 at low load only | README "Validation" | The harness is unvalidated where the top ceilings live | open (§8) |
| D11 | `full-pass.sh` looked up `^rust:` but the entry starts `GWS="rust:`; the empty service name matched any gateway's `ok` line. An empty admission list made `sweep.py` sweep every gateway | `full-pass.sh`, `sweep.py` | Async Rust was admitted whether or not it passed conformance | **fixed** (exact match, fail-closed; sweep needs keys or `--all`) |
| D12 | Session tasks were never joined; each task merged its lag histograms and recorded its outcome *after* releasing its channel senders | `main.rs` | Counters could be read before the last updates (a race; not reproduced); panics weren't collected | **fixed** (all tasks joined; a panic is a `harness_faults` INVALID) |
| D13 | A response that failed decoding or `validate()` ended the session as a protocol error | `process_inbound` | A malformed response spent the error budget instead of failing correctness | **fixed** (`malformed_message` / `invalid_partial` correctness errors, at any time; the session continues) |
| D14 | Latency histograms get one sample per partial; the README calls the gates "per audio frame" | `main.rs`, README | A large slow batch weighs the same as a small one; implementations that batch differently are compared on different populations | open (§5.4, Q5) |
| D15 | Summary/warn filenames are `<label>-<sessions>`; repeats and A/B variants overwrite each other | `run_point.sh` | Only the last attempt's summary survives (e.g. the two run3 rust-sync 4800 attempts) | open (§6) |
| D16 | The inference simulator draws latency jitter unseeded | `services/inference-server/src/main.rs` | Paired runs of two builds see different delay sequences, which adds variance to every comparison | open (§9) |
| D17 | 2-vCPU shapes are admitted on their 1-vCPU image's conformance; `inflight_model_jobs` is required but never bounded; conformance never runs under load | `full-pass.sh`, `stt-conformance.rs` | The one-in-flight invariant and the final 2-vCPU config are untested | open (§10) |

## 3. Architecture

```
loadgen (record only) ─► run dir (durable, unique) ─► stt-eval (offline) ─► verdict.json ─► sweep / experiment driver
  raw events in RAM        run.json, sessions.jsonl,     cohorts, verify,       PASS/FAIL/INVALID   bracket or paired
  written once at end      frames.bin, inbound.bin,      gate, self-check       + all metrics       comparison on
                           LOADGEN_MANIFEST,             (versioned SLO)                            verdicts only
  runner ─────────────────►runner.json, RUN_MANIFEST
```

- `stt-eval` is a new binary in the `stt-loadgen` crate. It reuses `verify.rs`, `protocol.rs` and `stt_stub::compute_stub`. The independent Python goldens (`services/python-fastapi/tests/`) remain the cross-check against a bug shared by stub and verifier.
- The SLO gates move into a versioned `scripts/bench/slo.toml`; its hash is in every verdict. `eval_slo.py` becomes a thin wrapper, then goes away.
- Published tables (README, `BENCHMARK.md`) are generated from verdicts and sweep results, never typed by hand.

## 4. Recorder (loadgen)

### 4.1 Hot-path rules

- No file I/O, no cross-session locks, no channel sends, no JSON parsing, no verification in the session loop.
- Each session owns preallocated buffers sized from the run plan. Memory is bounded: the plan is rejected at startup if its worst-case size exceeds a configured budget. A regrowth is counted and reported; on its own it does not invalidate the run.
- The receive timestamp is taken immediately after `read.next()` returns.
- An atomic message counter may feed a stderr progress line. It plays no part in the verdict.

### 4.2 What is recorded

Times are microseconds since the run epoch (monotonic), stored as `u32`. A plan longer than 71 minutes is rejected.

**Per frame** (`frames.bin`, per-session blocks, 12 bytes/frame). The schedule is not stored: `sched_k = first_tick + (k-1) × 20 ms`.
- `attempt_us`: when the tick's send started
- `done_us`: when `send().await` returned
- `status u8`: completed / timed out / failed (attempted-but-not-completed frames must be distinguishable from delivered ones)

**Per inbound WebSocket message** (`inbound.bin`, length-prefixed): `session u32`, `recv_us u32`, `opcode u8`, `len u32`, raw bytes; close records carry code and reason. A message over 64 KiB keeps its first 64 KiB with a `truncated` flag (a gateway protocol error, since partials are under 1 KiB).

**Per session** (`sessions.jsonl`): planned start, connect start/end, start-message sent, `first_tick`, frames attempted and completed, close sent, end, `outcome` (`ok`, `connect_timeout`, `connect_error`, `send_timeout`, `close_grace_timeout`, `session_timeout`, `closed_by_server`, `ws_error`, `task_panic`) with error text, regrowths. **Every planned session has a line**, including sessions that never connected; the recorder joins every task and writes `task_panic` for any that didn't return.

**Per run** (`run.json`): format version, all CLI arguments, loadgen git SHA, Tokio worker count, the plan (session count, ramp, spread, warmup, measure, observation margin), the epoch as monotonic and realtime plus once-per-second (monotonic, realtime) pairs with their read uncertainty (for aligning with cAdvisor, `/proc/stat` and packet captures; not used to judge), process CPU time and peak RSS, and counter reconciliation (frames recorded = frames attempted; inbound records = messages read).

### 4.3 Memory budget

At 8000 sessions on the current plan (about 3,500 frames/session on average plus the observation margin): frames ≈ 8000 × 3,750 × 12 B ≈ 360 MB; inbound ≈ 8000 × 75 × ~370 B ≈ 220 MB. Today's `sent_times: Vec<Instant>` alone is 16 B/frame ≈ 450 MB. The loadgen limit is 4 GiB by default.

### 4.4 Sealing

After all tasks are joined, write each file to `.tmp`, `fsync`, rename; then write `LOADGEN_MANIFEST.json` (format version, file sizes, SHA-256, record counts) the same way and `fsync` the directory. This is the only place `fsync` belongs; calling it mid-run would itself delay sends.

A process can't record its own OOM kill or deadline. The **runner** therefore writes `runner.json` from outside the pod and then seals both manifests with `RUN_MANIFEST.json` (§6). An artifact without `RUN_MANIFEST.json` is INVALID.

## 5. Evaluator (`stt-eval`)

### 5.1 Inputs and outputs

`stt-eval <run-dir> --slo scripts/bench/slo.toml [--legacy]` → `<run-dir>/verdict.json`, plus one stdout line in today's `eval_slo` format during migration.

`verdict.json`: verdict, ordered reasons, every metric below, **the margin to each gate** (e.g. newest p50 = 187 ms, margin 13 ms), evaluator SHA, SLO hash, and a per-second time series (partials/s, newest p50, harness-attributed lag p99, error count).

### 5.2 Measurement cohorts and the observation margin

- The plan adds an **observation margin** `M` after `measure_end` (default `M = FLUSH_INTERVAL + 2 × GATEWAY_INFERENCE_TIMEOUT` = 5 s). Sessions keep sending through `M`, so the last measured audio is answered under full load rather than an unloaded drain. Then they stop sending, keep receiving until the gateway closes or a drain deadline passes, and close.
- **Measured frame:** `sched_k ∈ [measure_start, measure_end)`.
- **Measured response:** a partial or error frame covering at least one measured frame. Each measured frame is covered at most once, because responses tile the sequence.
- **Outcome of every measured frame:**
  - *answered* by a partial (latency = `recv_us − sched_k`)
  - *errored* by an error frame
  - *lost*: never covered by the time its session ended
  - Lost measured audio is a correctness failure. The 300-frame tail tolerance applies only to audio scheduled after `measure_end + M`. This closes the D6 terminal-silence false pass.
- **Boundary batches:** a response straddling `measure_start` or `measure_end` counts as measured. Its frame-weighted metrics use only its measured frames.
- **Exposure:** every planned session counts. A session that failed to connect before the window still reduced the offered load, and is an admission failure (§5.4).
- `--legacy` reproduces today's receive-time window, post-decode timestamp and per-partial weighting. It exists only for the parity test (§8.2).

### 5.3 Checks, every response, no sampling

1. **Strict parse and `validate()`.** A failure is a `malformed_message` / `invalid_partial` correctness error wherever it occurs (matches the patched loadgen).
2. **Continuity:** responses tile `1..=frames_completed` per session.
3. **Causality:** a response may only cover frames whose `done_us` precedes its `recv_us`. With one task per session this equals today's unsent-frame check; it becomes stronger if send and receive are ever split.
4. **Stub values:** `verify_partial` plus the echoed `cpu_passes` and `model_delay_ms`, run in parallel. Coverage is 100% by construction and asserted.
5. **Lost measured audio** (§5.2) and the post-margin tail tolerance.
6. **Session outcomes**, for every planned session.

### 5.4 Metrics and gates

- **Latency** is reported both ways:
  - *per response* (today's population): `recv − sched(newest)`, `recv − sched(oldest)`;
  - *per measured audio frame*: `recv − sched_k` for every answered frame. This is what "per audio frame" in the README promises.
  - Which one the gates use is Q5. Quantiles are exact, using a stated nearest-rank convention.
- `flush_lateness` comes from the partials, as today. It is gateway-reported and not used for attribution.
- **Errors**, counted separately, all in the measured exposure:
  - (a) *admission*: planned sessions that never streamed;
  - (b) *session*: sessions that failed after streaming started;
  - (c) *audio*: measured frames errored or lost.
- **Error budget** (Q2): against offered exposure, `planned sessions × measured flush opportunities`, so neither extra nor missing partials change the budget. Lost audio is also a correctness failure (§5.2); errored audio is spent from the budget.
- **Gates:** the existing thresholds, read from `slo.toml`.

### 5.5 Harness self-check (INVALID, never FAIL)

| Check | Rule |
|---|---|
| Artifact | `RUN_MANIFEST.json` missing or not matching; loadgen exit non-zero or killed (from `runner.json`); format version unknown; counters don't reconcile |
| Recorder | any `task_panic`; truncation of a non-gateway cause |
| Send-side harness lag (per event) | For each measured frame, lateness `attempt_k − sched_k` is **gateway-attributed** when it's explained by blocked previous writes (`attempt_k ≈ done_{k-1}` and `done_{k-1} − attempt_{k-1}` beyond a threshold). Otherwise it's **harness-attributed**: the task woke late with no blocked write. INVALID when harness-attributed lag p99 > 10 ms, on any verdict whose gates are only latency, or on a PASS. |
| Receive-side lag | No in-band signal. Bounded by calibration (§8.4); a run above the calibrated session count is marked `outside-calibrated-range` and cannot be published. |
| Placement | Effective CPU affinity of the gateway's threads, the loadgen and inference (from `runner.json`) doesn't match the declared placement |

Clock: monotonic durations are trusted. Realtime pairs are only for alignment, with their uncertainty recorded, and never invalidate a run (NTP rate adjustment is parts per million, so microseconds on a 200 ms interval).

## 6. Runner and transport

- The loadgen Job mounts a dedicated results PVC at `/results`. The run directory is `<label>-<sessions>-<UTC timestamp>-<random>`; it is immutable and never overwritten (fixes D15).
- After the Job ends, the runner writes `runner.json`:
  - the Job and container exit status and termination reason (OOMKilled, deadline);
  - the executed `imageID` digests of loadgen, gateway and inference pods;
  - node, CPU quota, and effective affinity read from `/proc/<pid>/status` (`Cpus_allowed_list`) of every gateway thread;
  - the gateway's restart count before and after.
- The runner then exports the run directory, verifies `LOADGEN_MANIFEST.json` hashes locally, writes `RUN_MANIFEST.json` and only then lets the Job be deleted.
- Pod logs are saved as `loadgen.log` for humans and never parsed for data.
- Images are referenced by digest (fixes D9).
- If the deadline is hit, the Job is killed and the point is INVALID.

## 7. Search and experiments

**Ceiling sweeps** (`sweep.py`, already patched):
- A point is True / False / None (INVALID after its re-run). None steers the search like a fail but is never counted as one.
- The result lists `harness_capped`, and `bounded_by` is `harness` when a capped point sits below every real fail. Then the ceiling is a lower bound, not a measurement.
- Open:
  - **Fresh-start policy.** Restart the gateway before each point, or explicitly measure recovery: after an overload point, re-run a known-passing point and require it to pass. Today persistent state (e.g. C++ memory at 2.7 GiB after its 6000 point) leaks into later points.
  - **Confirmation strength.** Two passes is weak: a point with an 80% pass probability passes twice 64% of the time. Report `k/n` passes, and treat a ceiling as a probability-of-pass curve near the edge, not one number.
  - **Minimum across passes** is a selection effect (more reruns, more chances for a low minimum). Report every pass's bracket, not only the minimum.

**Hill-climbing comparisons** (new `scripts/bench/compare.py`). The question "is build B better than build A?" is answered by a paired experiment, not by two independent sweeps:
1. Fix a set of session counts near A's edge.
2. Run A and B interleaved, `ABBA…`, randomized per block, same pod shape, same placement, same seeded inference (§9).
3. Compare the gate margins per pair (e.g. newest p50 and p95 at each count), with a bootstrap confidence interval.
4. Declare a winner only if the interval excludes zero, then confirm on held-out repeats.

That detects improvements well below one sweep step and doesn't depend on the bracketing search.

## 8. Proving the harness correct (acceptance criteria)

Each item passes before any new number is published.

### 8.1 Evaluator tests on synthetic artifacts
- One artifact per mismatch kind and per outcome.
- Window edges (`measure_end ± 1 µs`), boundary batches, a measured response arriving after `measure_end`.
- **Terminal silence**: a gateway that answers normally and then goes quiet for its last 4 s of measured audio. Must FAIL as lost audio. Today it passes.
- A failed admission before the window; every timeout kind.
- A corrupt or missing manifest; counters that don't reconcile; `task_panic`.
- Deterministic: re-evaluation gives byte-identical `verdict.json`.

### 8.2 Parity with today's pipeline
- On ≥ 6 real points (3 runtimes × pass/fail edge), the recorder also emits the legacy summary behind a migration flag.
- `stt-eval --legacy` must match the legacy counts exactly and the quantiles to within HDR's 3-significant-figure resolution.
- Each intended change (pre-decode timestamp, cohorts, observation margin, frame weighting, exposure denominator) is then applied one at a time, with its effect reported.
- Performance acceptance (§8.5) runs with the legacy path disabled.

### 8.3 Tracked mutation suite
- Mutants live in the repo (`scripts/bench/mutants/`, one patch per mutant against a reference gateway) with a runner that conforms and measures each.
- The existing 13 categories are re-created and must all be caught, plus:
  - terminal silence;
  - a partial reporting a frame before receiving it;
  - a malformed partial (must be a correctness FAIL, not budget);
  - **socket back-pressure**: the gateway stops reading for a stated duration with a small `SO_RCVBUF`, so loadgen writes provably block. Must be classified gateway-attributed; its expected SLO outcome is computed from the injected stall, not assumed;
  - a loadgen killed mid-run and a loadgen OOM (INVALID).

### 8.4 Calibration at and beyond the operating range
At 1000, 4000, 8000 and 10000 sessions:
- **Reference gateway with proven headroom.** Correct partials, no inference work, its own CPU well under its quota, ~0 flush lateness. Measure residuals against an **analytical timing model**: frame phase within the flush, model delay, transport. Not against "zero". The highest session count where residual p99 ≤ 2 ms is the harness's valid range; numbers above it are not publishable.
- **Injected delay distributions**, not just constants: 0 / 50 / 150 / 300 ms, plus a heavy-tailed mix. Check p50 *and* p95 tracking, and the absolute baseline, not only relative shifts.
- **Kernel observation point.** Packet capture with kernel software timestamps on the loadgen pod's interface, for a sampled 1% of sessions. Reconstruct the TCP byte stream and WebSocket messages. Define complete-message arrival as the kernel timestamp of the segment carrying a message's last byte. Report separately:
  - receive-observation lag: `recv_us` − arrival;
  - transmit queueing: departure of a frame's last byte − `done_us`;
  - conversion uncertainty between the two clocks.
  - Acceptance: receive-observation lag p99 ≤ 2 ms inside the valid range.
- **Loadgen-resource robustness.** At the top valid count, vary loadgen cores and placement while holding gateway and backend fixed. The reference gateway's verdicts and margins must not move beyond noise.
- **Co-location interference.** Repeat the reference at the top valid count with and without a memory-bandwidth-heavy neighbour on the gateway CPUs. This bounds the shared-memory effect for the reference workload only (see §10).

### 8.5 Recorder overhead
Against the reference gateway at 4000 and 8000, loadgen CPU and harness-attributed lag p99 must be no worse than today's fixed loadgen (`harness-fix`: 3.7 cores at 6000, 5.1–5.3 at 8000, send-lag p99 ≤ 4 ms).

### 8.6 Experimental-design checks
- **Repeat confidence:** the same build run 10× at one point near its edge gives a pass-rate and margin distribution. This sets the noise floor that `compare.py` must beat.
- **Order independence:** shuffled point order gives the same per-point outcomes.
- **Overload recovery:** a known-passing point after an overload point passes, or the fresh-start policy is enforced.
- **Warmup stability:** per-second metrics are stationary across the measured window (no JIT/GC trend).

## 9. Seeded inference latency

The simulator draws per-request delay from a seed derived from a hash of the request body (the PCM is deterministic per session and frame range) plus `x-cpu-passes`. Identical batches then get identical delays across gateways and repeats, so paired comparisons see the same backend. Gateways that batch differently still see different sequences, but each batch's delay is reproducible.

## 10. What this does not cover

- **Interference through the shared memory system** (DRAM bandwidth, L3, package power). It's measured for the reference gateway (§8.4), not eliminated, and real runtimes have different memory traffic. In particular, both Rust gateways zero-fill a 128 KiB tungstenite read buffer per session (rust-axum's RSS was 128 KiB × sessions in run3). That interference is runtime-specific, not a uniform offset.
- **A bug shared by the stub and the verifier.** Only the Python goldens are independent.
- **Gateway-side resource metrics** (cAdvisor) are aligned by time but not re-validated.
- **Conformance gaps** (D17): it doesn't prove 1000 ms batching under saturation, a bounded `inflight_model_jobs`, or the one-in-flight invariant under load, and 2-vCPU configs aren't conformance-tested on their own. A follow-up adds an under-load conformance case that checks `inflight_model_jobs ≤ 1` per session and runs on every published pod shape.
- **Deployment realism.** "1 vCPU" is a CFS quota across two hyperthreads on two P-cores; the loadgen's 8 CPUs are four P-cores with SMT. These are deliberate and stated, not single-core capacity.

## 11. Open decisions (recommended answers)

- **Q1. Window:** scheduled-audio cohorts with an observation margin under load and complete outcome accounting (§5.2). Version the semantics; old and new numbers are never mixed.
- **Q2. Error denominator:** fixed offered exposure, with admission, session and audio errors reported separately. (Rev 1's reasoning was backwards: today fewer partials make the budget *tighter*. The real reason is that the budget shouldn't depend on how many partials a gateway chooses to send.)
- **Q3. Storage:** a dedicated results PVC plus verified local export before deletion; immutable run directories.
- **Q4. Evaluator language:** Rust in the loadgen workspace, keeping the independent Python goldens and synthetic-artifact tests.
- **Q5. Latency population for the gates:** per audio frame (matches the SLO's stated intent and weighs batching fairly) or per response (today). Both are always reported. Recommended: gate per audio frame, version-bumped with Q1.

## 12. Rollout

0. **Verdict-integrity patch, done (uncommitted):**
   - INVALID is preserved through the sweep;
   - no-json, a loadgen crash, kill or deadline is INVALID;
   - a malformed summary or missing fields is INVALID;
   - a PASS requires complete verification;
   - harness lag invalidates a PASS too;
   - session tasks are joined, and panics become `harness_faults`;
   - malformed responses are correctness errors;
   - conformance admission fails closed;
   - `just harness-test` runs in `analysis-check`.
   - Loadgen images built before this patch lack `harness_faults`, so every point they measure is now INVALID until the image is rebuilt.
1. `stt-eval` and the artifact format, with synthetic tests (§8.1).
2. Recorder, keeping the legacy summary behind a migration flag.
3. Runner/transport (§6), sweep fresh-start policy (§7), seeded inference (§9).
4. Parity (§8.2) and the tracked mutation suite (§8.3).
5. Reference gateway, calibration and packet capture (§8.4–8.6); publish the harness's valid range and noise floor.
6. `compare.py` for paired comparisons (§7).
7. Remove the legacy path. Re-sweep with the validated harness, starting with the high-capacity runtimes most exposed to the old loadgen. Keep historical numbers clearly versioned.
