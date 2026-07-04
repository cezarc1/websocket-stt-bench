# OxCaml Bottleneck Profiling Plan

## Goal

Find the current bottleneck in `services/ocaml-oxcaml` and test whether focused
changes can move the confirmed 1-vCPU ceiling from `2075` sessions/vCPU closer
to the TypeScript/Bun (`2550`) or Java/Helidon Nima (`2625`) tier without
changing the benchmark contract.

All headline claims must use the existing Kubernetes harness:

- `scripts/bench/run_point.sh`
- `scripts/bench/ladder.sh`
- `scripts/bench/eval_slo.py`

Local runs are only for hypothesis filtering.

## Current Evidence

- OxCaml baseline: `2075` confirmed, `2100` borderline, `2125` first solid
  fail, CPU-bound on one Async domain.
- Stock OCaml raw Async transport: `1930` confirmed. The gap to OxCaml is real
  but modest once transport shape is held mostly constant.
- Rust `mio` result suggests architecture matters more than micro-optimizing
  the same loop: splitting inference work to a second OS thread moved the
  confirmed ceiling from `3150` to `4400`.
- Java reaches `2625` on 1 vCPU with virtual threads and an HTTP/2 client pool,
  then fails through latency and heap pressure.

## Main Hypotheses

1. **Single Async-domain contention**
   WebSocket reads, flush scheduling, HTTP request/response, response JSON
   parsing, partial JSON serialization, and outbound writes all cooperate on
   one scheduler. Inference bursts may delay fresh-frame responsiveness the same
   way the single-loop Rust prototype did.

2. **Per-flush allocation pressure**
   `Session.drain` allocates list cells and accumulator records, then reverses
   the frame list. `Protocol.Partial.to_string` allocates a `Buffer`, numeric
   strings, and `sprintf` output per partial. `Inference.write_request` allocates
   the `Content-Length` line per flush.

3. **Protocol parsing/serialization cost**
   The success path avoids Yojson for outbound partials, but response parsing
   still builds a Yojson tree. This may matter at roughly 2k flushes/s.

4. **GC/runtime tuning**
   Jane Street's OxCaml GC improvements may help only if measured allocation or
   GC time is meaningful at the edge. Tune after measuring, not before.

5. **OxCaml zero-allocation guardrails**
   `[@zero_alloc]` is likely useful for leaf helpers, not the full Async call
   tree. Good candidates are pure or in-place helpers such as frame unmasking
   and simple numeric helpers. It should be treated as a correctness guardrail
   against allocation regressions, not assumed to improve throughput alone.

## Profiling-First Harness

Add diagnostics behind environment flags so normal benchmark behavior remains
unchanged:

- `OXCAML_DIAG=1`: enable low-rate aggregate counters.
- `OXCAML_DIAG_INTERVAL_MS=5000`: emit JSON summaries to stderr every interval.
- `OXCAML_DIAG_SAMPLE_EVERY=N`: optionally sample expensive timing every N
  flushes.
- `OXCAML_TRACE=1`: enable sampled Chrome trace-event output using Jane
  Street's `chrome-trace` library.
- `OXCAML_TRACE_FILE=/path/to/trace.json`: write a complete trace JSON snapshot
  suitable for `chrome://tracing` or Perfetto.
- `OXCAML_TRACE_SAMPLE_EVERY=N`: sample trace spans independently from the
  aggregate diagnostic sampling rate.
- `OXCAML_TRACE_FLUSH_INTERVAL_MS=1000`: periodically rewrite a valid trace
  file so a stopped local run still leaves inspectable output.
- `OXCAML_TRACE_FRAME_SAMPLE_EVERY=500`: emit sampled `binary_frame` instant
  events without tracing every audio frame.
- `OXCAML_TRACE_MAX_EVENTS=200000`: cap retained sampled events and report
  dropped events in the trace root metadata.

Minimum counters:

- session count opened/closed
- binary frames accepted
- flush ticks
- flush skipped because no capability/inflight
- flush skipped because buffer empty
- batches sent
- batch frame count and body bytes
- inference elapsed ms histogram summary
- serialize elapsed ms sampled summary
- outbound pipe write elapsed ms sampled summary
- response parse elapsed ms sampled summary
- `Gc.quick_stat` deltas: minor words, promoted words, major words,
  minor collections, major collections, compactions

Diagnostics must write only logs. They must not change protocol fields,
flush cadence, close codes, SLO thresholds, pod shape, loadgen timings, or
default runtime behavior.

## Experiment Loop

For each idea:

1. Record the hypothesis in `services/ocaml-oxcaml/BENCHMARK.md` or a temporary
   experiment note before changing the README headline.
2. Write or extend a focused test if behavior changes.
3. Run `just ocaml-test`; use `just ocaml-check` before any k3s run.
4. Run a local smoke only to reject obviously bad ideas.
5. Run k3s points with the official harness at `2000`, `2075`, `2100`, and
   `2125`.
6. If the edge moves, bracket with divide-and-conquer and repeat the top pass.
7. Keep only changes that improve the SLO edge or materially improve evidence.
8. Never report a single pass as confirmed.

## Candidate Experiments

### A. Diagnostics Only

Add the `OXCAML_DIAG` counters and prove they are off by default.

Validation:

- `just ocaml-test`
- `just ocaml-check`
- `just conformance`
- one local Compose smoke with diagnostics off
- one local Compose smoke with diagnostics on, confirming extra stderr only

### B. Drain Representation

Replace per-flush list construction and reversal in `Session.drain` with a
representation that avoids list cells or reuses a persistent buffer. Preserve
the no-concat request write unless measurement proves concat is faster.

Validation target:

- identical partial sequence fields
- no protocol conformance regression
- lower allocation per flush in diagnostics

### C. Partial Serialization

Reduce allocations in `Protocol.Partial.to_string` by replacing `sprintf` and
per-field numeric string creation where practical. Keep the exact-field-set
round-trip tests.

Validation target:

- `test_partial_to_string_roundtrips`
- diagnostics show lower serialize time or allocation

### D. Inference Isolation

Prototype a Rust-sync-style split: move inference request/response work off the
main Async scheduler, or build a bounded worker path that returns results to the
session without relaxing one-inflight-per-connection.

This is the highest-upside and highest-risk path.

Validation target:

- lower flush lateness and newest-frame latency near `2075+`
- no new timeout/retry behavior
- one-inflight invariant remains explicit

### E. Response Parsing

Replace Yojson response parsing with a narrow parser for the inference server's
fixed JSON envelope only if profiling shows response parse cost matters.

Validation target:

- strict unknown-field rejection remains
- same error frame behavior on malformed inference responses

### F. Runtime/GC Knobs

Try OCaml runtime environment settings only after diagnostics show GC pressure.
Record every knob with exact values and revert knobs that do not move the k3s
SLO edge.

## Success Criteria

- Useful: `2125` becomes repeat-confirmed.
- Strong: `2400+` confirmed.
- Target: `2550-2625` confirmed, matching the TypeScript/Bun to Java tier.
- Negative result: an evidence-backed explanation of why the current Async or
  allocation shape blocks the target.

## Gates

- Ask before cluster scaling, Helm deploys, or CI image dispatch.
- Ask before updating README, chart, or published capacity claims.
- Do not change loadgen settings, SLO thresholds, flush interval, pod shape, or
  protocol schema to improve the number.
- Leave cluster deployments scaled back to zero and delete loadgen jobs after
  benchmark runs.
