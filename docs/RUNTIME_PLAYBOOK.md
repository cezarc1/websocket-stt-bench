# Runtime Playbook — adding a language/runtime to websocket-stt-bench

**Purpose.** A reproducible, agent-executable procedure for adding one new
language/runtime gateway to this benchmark, measuring it on equal footing with
the others, and recording the result honestly. Inspired by Karpathy's
[autoresearch](https://github.com/karpathy/autoresearch) `program.md`: this file
*is* the program an agent runs; a human only steps in at the gates marked
**[ASK]**.

The output for a new runtime is three artifacts, in priority order:

1. A gateway that is an **exact black box** — indistinguishable from every other
   gateway through the shared WebSocket protocol (`just conformance` is the
   judge).
2. A **comparable capacity number** (sessions/vCPU at 1 and 2 vCPU) produced by
   the *identical* measurement methodology as every other runtime.
3. An **Agent Build Log** — how much autonomous debugging the runtime needed.
   This is a first-class result, not a footnote: "perf per LOC" and
   "agent-debuggability" are co-equal axes of this benchmark.

**Reference example — what "done" looks like:**
[PR #1](https://github.com/cezarc1/websocket-stt-bench/pull/1) (the OCaml/OxCaml
run this playbook was extracted from). Use its PR body as the template for the
final artifact: the summary, the checked test-plan, the `confirmed ↔ borderline
↔ first-solid-fail` bracket, and a filled-in Agent Build Log.

---

## The two contracts (read first, never violate)

### A. Black-box protocol contract

The new gateway must be byte-for-byte substitutable for any existing one. The
**single source of truth** is `CLAUDE.md` → "Shared protocol contract" plus
`loadgen/rust/src/protocol.rs` and the `stt-conformance` binary. Do not
re-derive it from another gateway's code (that copies its bugs). Non-negotiable
surface:

- `GET /ws/stt` → WebSocket upgrade; `GET /health` → 200.
- Client sends `{"type":"start"}` (text). Then 16 kHz mono PCM, **640 bytes /
  binary frame**, 50 fps.
- Server buffers per connection, flushes every **1000 ms**, POSTs the
  concatenated PCM to the inference server, relays a `partial` JSON.
- `partial` **must** carry `oldest_frame_seq`, `newest_frame_seq`,
  `flush_lateness_ms`, `inflight_model_jobs` (loadgen computes latency curves
  from these — wrong/missing = the run is meaningless).
- **At most one in-flight inference request per connection** — the load-bearing
  invariant. Back-pressure must surface as growing oldest-frame latency, never
  unbounded task spawning. Model it idiomatically for the runtime, but it must
  hold at runtime.
- Invalid first message → close **1002**. Wrong binary frame size → close
  **1003**. Normal client close → prompt, no final drained partial required.
- Strict JSON at both boundaries (reject unknown fields), mirroring serde
  `deny_unknown_fields` / Pydantic `extra="forbid"`.

If anything here is ambiguous for your runtime, that is an **[ASK]**, not a
guess.

### B. Comparability / measurement contract

A capacity number is only comparable if produced identically. Fixed for every
runtime — do **not** tune per-gateway:

- Pod shape: **1 vCPU / 2 GiB** (and **2 vCPU / 2 GiB**), dedicated inference
  with structural headroom (co-located inference invalidates the number).
- Loadgen: **10 s warmup / 45 s measured / 30 s ramp / 1000 ms session-start
  spread**, 1 repeat per point.
- SLO gates (in `scripts/bench/eval_slo.py`, identical for all): newest p50 ≤
  200 ms, newest p95 ≤ 350 ms, oldest p50 ≤ 1200 ms, oldest p95 ≤ 1650 ms,
  error rate ≤ 1e-5.
- **Confirmed** = the headline ceiling passed *and a re-run also passed*.
  **Borderline** = 1 pass / 1 fail (report as borderline, never as the
  headline). **First solid fail** = the lowest count that fails on repeat.
- Report the bracket `confirmed ↔ borderline ↔ first-solid-fail`, the failing
  gate, and whether errors were zero (a clean latency edge) or an error cliff.

The harness that encodes this is `scripts/bench/{run_point.sh,ladder.sh,
eval_slo.py}`. Use it; do not hand-roll loadgen invocations.

---

## Honesty rules (these define the project's credibility)

- Never fabricate, round-fit, or interpolate a number. Every reported point
  comes from a real run whose summary JSON exists.
- A pass you didn't re-run is not "confirmed". Say "borderline" when it is.
- Never claim a runtime/language feature you did not actually exercise (e.g.
  don't say "uses X's parallelism" if the code doesn't). If a celebrated
  feature turned out inapplicable, *say why* — the negative result is valuable
  (see the OxCaml `janestreet/parallel` finding in `README.md`).
- Report the error mode honestly: zero-error latency edge vs. error/OOM cliff
  are different stories.
- Record what the agent **could not** do without the human. Struggling is data.
- Findings in `README.md` are **succinct**. Depth goes in the detailed-sweep
  section, not the TL;DR.

## Human-in-the-loop gates — stop and ask ONLY here

Everything else is autonomous. **[ASK]** at exactly:

1. **Plan approval** (Phase 0) — runtime choice, libraries, the differentiator,
   the LOC budget. Use plan mode.
2. **Genuine protocol ambiguity** — a contract case the spec doesn't settle.
3. **Shared-state / irreversible ops** — pushing a branch, dispatching CI,
   scaling cluster deployments, opening a PR. Propose, then wait.
4. **A wall after honest effort** — you've tried N independent approaches to a
   build/debug blocker and are out of non-speculative options. Surface it with
   what you tried (and log it — see the Build Log).

---

## Phases

Phases 0–4 are **portable** (any agent, any machine). Phases 5–6 need *a*
Kubernetes cluster + the methodology above; homelab specifics are Appendix A.

### Phase 0 — Plan  ([ASK] gate)

1. In **plan mode**, research the runtime's idiomatic async/IO stack, WebSocket
   + HTTP-client libraries, JSON-with-strict-unknown-fields, test/lint/format
   tooling. Prefer the *idiomatic* choice for the runtime over a familiar one;
   the point is to evaluate the runtime as its community would write it.
2. Pick the **differentiator**: the one thing this runtime expresses better
   than the others (Rust `Semaphore`, Elixir process-per-conn, OxCaml
   capability type…). It sharpens the README narrative.
3. State a **LOC budget** (compare to the existing band in README "How the code
   turned out").
4. Present the plan. **Wait for approval.**

### Phase 1 — Implement to the contract

- Scaffold `services/<runtime>/`, a pinned toolchain entry in
  `versions.lock.toml`, a `just <runtime>-check` recipe (mirror an existing
  one's shape), `scripts/ensure-*.sh` if a toolchain bootstrap is needed,
  `scripts/doctor.sh` checks, `docker/<runtime>.Dockerfile`,
  `docker-compose.yml` `single`/`multi` services on a free port, the Helm
  `charts/stt-bench/values.yaml` gateway block, and the `.github/workflows/
  images.yml` build-matrix entry.
- Implement the gateway against **contract A** (not by reading another
  gateway's internals). Keep the inflight invariant idiomatic but real.
- Gate: the language's own formatter + linter + unit tests pass. Add unit
  tests for the protocol edges (start validation, frame-size close, strict
  JSON, the partial field set).

### Phase 2 — Conformance (hard gate)

1. `just compose-build` then `just conformance`. Add your service to the
   `conformance` recipe's compose list and `--service <name>=ws://<name>:<port>/ws/stt`.
2. All five cases must pass: partial schema+golden, invalid-start→1002,
   invalid-frame→1003, flush cadence, normal close.
3. **Do not proceed to measurement until conformance is green.** A fast/buggy
   gateway is not a result.

### Phase 3 — `/simplify` + re-verify

1. Run the `/simplify` skill (reuse / quality / efficiency review of the diff).
   Fix real findings; skip false positives without arguing.
2. Aim for the bar "would a senior engineer in this language sign off on it":
   tight modules, narrow interfaces, illegal states unrepresentable where the
   language allows, no fake abstraction, no comment bloat.
3. Re-run the full local gate (`just <runtime>-check`, `just conformance`).
   The cleanup must not regress conformance. Add a regression test for any real
   bug the round uncovered.

### Phase 4 — Build the image  ([ASK] before dispatching)

- Portable path: `just compose-build` builds the image locally for the
  Compose conformance/smoke.
- Cluster path: the amd64 image must reach the registry the cluster pulls
  from. In this repo that is the CI workflow:
  `gh workflow run images.yml --ref <feature-branch>` (workflow_dispatch has
  `packages: write`). Confirm the `<runtime>` matrix job is `success`
  (independent of other matrix jobs that may fail on unrelated push perms).
  Dispatching CI / pushing a branch is an **[ASK]**.

### Phase 5 — Deploy + smoke (cluster)

1. Deploy via the Helm chart (`charts/stt-bench/`, canonical) or a standalone
   Deployment+Service; **1 replica, 1 vCPU / 2 GiB**, dedicated inference.
   Scaling a cluster deployment is an **[ASK]**.
2. Force the fresh image (`imagePullPolicy: Always` + rollout restart), wait
   Ready, confirm exactly one ready pod and the correct image digest.
3. Functional smoke: `SVC=.. PORT=.. LABEL=..-1vcpu-2gib
   scripts/bench/run_point.sh 50`. Require **err=0** and latencies in band.
   This is the cluster-side conformance check.

### Phase 6 — Divide-and-conquer the ceiling (1 vCPU, then 2 vCPU)

1. **1 vCPU.** Coarse ladder to find the pass→fail region, then bisect to a
   `pass ↔ first-solid-fail` interval ~one step wide, then **re-run the top
   pass to confirm**. Use `scripts/bench/ladder.sh`. Record the bracket, the
   failing gate, error mode.
2. **2 vCPU — measure both, honestly.** Many runtimes don't scale in-pod the
   way folklore says. Run **(A)** one 2-vCPU replica and **(B)** N×1-vCPU
   replicas behind the Service, and report which actually scales. If a
   runtime's headline concurrency feature turns out inapplicable, prove *why*
   (cite the API/type constraint, like the OxCaml `parallel @ once portable`
   finding) rather than hand-waving.
3. Keep cluster etiquette: touch only this gateway's Deployment + loadgen
   Jobs, never the other runtimes'; **return the deployment to `replicas: 0`**
   and delete loadgen Jobs when done; pass the kube context explicitly if it
   can flip.

### Phase 7 — Record findings (succinct) + graph

Edit `README.md` minimally and consistently (see Appendix B for the exact
spots): TL;DR table row + footnote, the "Surprising"/"How the code turned out"
bullets (this is where the differentiator + the honest negative results live),
"Which runtime?"/"Pod shape" guidance, "Run dates", and add a detailed-sweep
subsection with the real bracket tables. Keep the TL;DR terse; depth goes in
the sweep section.

Regenerate the graph: the data points are **hardcoded** in
`analysis/stt_analysis/comparison_chart_gen.py` — add a row to `RUNTIMES`
(tuple order: `name, sessions@1vCPU, LOC, dx, dy, ha`; only add to `PARETO`
if nothing else has both higher sessions *and* lower LOC), then run it from
the `analysis/` dir with an explicit out path back to repo `docs/`:
`cd analysis && ../.tools/bin/uv run python -m
stt_analysis.comparison_chart_gen --out ../docs/loc-vs-capacity.png`.

### Phase 8 — Memory, then PR  ([ASK] before opening the PR)

- Update agent memory with the *non-obvious* facts (why a lib was rejected,
  the measured ceiling + reason, what the mode/type system forced) — not
  things derivable from code or git.
- Run the full `just check` gate.
- Propose the PR (title + summary + the bracket + the Agent Build Log
  summary), structured like the reference [PR #1](https://github.com/cezarc1/websocket-stt-bench/pull/1).
  **Open it only after [ASK].**

---

## Per-runtime deliverables checklist

- [ ] `services/<runtime>/` gateway; `just <runtime>-check` green
- [ ] Wired into `versions.lock.toml`, `doctor.sh`, `docker-compose.yml`,
      `docker/`, Helm `values.yaml`, `images.yml`, `just check` aggregate
- [ ] `just conformance` green (all 5 cases)
- [ ] `/simplify` round done; re-verified no regression
- [ ] CI image job `success`; deployed; 50-session smoke `err=0`
- [ ] 1-vCPU bracket `confirmed ↔ borderline ↔ first-solid-fail`
- [ ] 2-vCPU measured both ways (in-pod vs replica fan-out)
- [ ] `README.md` updated (succinct) + `docs/loc-vs-capacity.png` regenerated
- [ ] Agent Build Log filled in
- [ ] Cluster returned to `replicas: 0`, loadgen Jobs deleted
- [ ] Memory updated; PR proposed

### Agent Build Log (required — paste into the PR body)

```
Runtime:                <name+version>
Production LOC / files: <n> / <n>
Autonomous debug iterations to first conformance-green: <n>
Bug classes hit (and how diagnosed):
  - <e.g. toolchain build failure / protocol misread / transport / perf cliff>
Points where HUMAN input was required (and why):
  - <e.g. ambiguous close-code case; CI/push approval; none>
Time-to-green (wall): conformance <…>, 1-vCPU confirmed <…>
Agent-debuggability score (1=trivial … 5=needed heavy human help): <n>
  Justification: <1-3 sentences — toolchain opacity, error-message quality,
  ecosystem gaps, how self-correcting the loop was>
Surprises / negative results worth keeping:
  - <e.g. celebrated feature X was inapplicable because <type/API constraint>>
```

This log is the operationalization of "C++ was hard for the agent to debug,
Python was trivial". Be candid; an honest 5 is more useful than a flattering 2.

---

## Appendix A — Homelab/k3s specifics (environment-dependent)

Not portable; substitute your cluster's equivalents. As used for the runs in
`README.md`:

- Single-node k3s on one Intel i9-13900F (32 logical CPU). 1-vCPU pods are CFS
  quota, not pinned — expect P/E-core edge variance; trust repeats + persisted
  CSVs.
- No passwordless `ctr` import and no local GHCR *write* token, and the node is
  amd64 while dev Macs are arm64 → the **only** image path is the `images.yml`
  workflow (`gh workflow run images.yml --ref <branch>`); pull via
  `ghcr-pull-secret`.
- `kubectl` context flips to `docker-desktop` when Docker Desktop touches kube
  → pass `CTX=<cluster-context>` to the harness / `--context` explicitly.
- Helm release is plain Helm (not Flux); a benchmark point = scale one gateway
  Deployment to the target replicas + run an in-cluster loadgen Job, then back
  to 0. Inference is a dedicated multi-replica deployment with CPU headroom.
- Results (`*.summary.json`/`*.samples.csv`) are gitignored artifacts; the
  harness writes them to `RESULTS_DIR` (default `/tmp/bench/results`). Keep
  them locally as the evidence; do not commit.

## Appendix B — Files every new runtime touches

`services/<runtime>/**`, `versions.lock.toml`, `scripts/doctor.sh`,
`scripts/ensure-*.sh` (if needed), `justfile` (`<runtime>-check` + the `check`
aggregate + `conformance` service list), `docker/<runtime>.Dockerfile`,
`docker-compose.yml` (`single`+`multi`), `charts/stt-bench/values.yaml`
(+ `values-homelab-example.yaml`), `.github/workflows/images.yml` build matrix,
`README.md` (TL;DR row + footnotes, Surprising / How-the-code-turned-out,
Which-runtime / Pod-shape, Run dates, detailed sweep subsection),
`analysis/stt_analysis/comparison_chart_gen.py` (`RUNTIMES`/`PARETO`) →
regenerate `docs/loc-vs-capacity.png`.
