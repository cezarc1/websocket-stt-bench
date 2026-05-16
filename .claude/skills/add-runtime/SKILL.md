---
name: add-runtime
description: Use when adding a new language/runtime gateway to the websocket-stt-bench benchmark, or when measuring/recording an existing one's sessions-per-vCPU. Drives the full reproducible procedure — plan → implement to the shared WebSocket protocol → conformance → /simplify → CI image → cluster deploy → 1-vCPU then 2-vCPU divide-and-conquer ceiling sweep → succinct README + graph → PR — with the agent autonomous except at explicit human-in-the-loop gates.
---

# add-runtime

The full procedure lives in **`docs/RUNTIME_PLAYBOOK.md`** — read it now and
follow it phase by phase. This skill is the trigger + the non-negotiables;
the playbook is the program.

## Do this

1. **Read `docs/RUNTIME_PLAYBOOK.md` end to end before acting.** It is the
   source of truth for the procedure, the contracts, and the gates.
2. Track the work with the per-runtime deliverables checklist from the
   playbook (use TodoWrite/TaskCreate).
3. Stay autonomous except at the four **[ASK]** gates: plan approval,
   genuine protocol ambiguity, shared-state/irreversible ops (push, CI
   dispatch, cluster scale, PR), and a real wall after honest effort.

## Never violate

- **Black-box contract:** the new gateway is judged only by `just
  conformance` + identical wire behavior. Source of truth is `CLAUDE.md`
  "Shared protocol contract" + `loadgen/rust/src/protocol.rs` +
  `stt-conformance` — not another gateway's internals.
- **Comparability contract:** measure with `scripts/bench/{run_point,ladder,
  eval_slo}` only. Fixed for all runtimes: 1/2-vCPU·2 GiB pods, dedicated
  inference, 10/45/30 s + 1000 ms, the SLO gates, and
  `confirmed (repeat-pass) ↔ borderline ↔ first-solid-fail` bracketing.
- **Honesty:** never fabricate/interpolate a number; "borderline" ≠
  "confirmed"; never claim a runtime feature you didn't exercise (prove a
  negative result instead); record what needed human help.
- **Conformance is a hard gate** — never measure capacity before
  `just conformance` is green.
- **Deliver the Agent Build Log** (autonomy/debuggability) — it is a
  first-class result alongside perf/LOC, not optional.

## Quickref

- Local gate: `just <runtime>-check`; aggregate: `just check`
- Conformance: `just compose-build && just conformance`
- Image (cluster): `gh workflow run images.yml --ref <branch>` **[ASK]**
- Sweep: `SVC=.. PORT=.. LABEL=..-1vcpu-2gib scripts/bench/ladder.sh <s…>`
- Graph: edit `RUNTIMES` in `analysis/stt_analysis/comparison_chart_gen.py`,
  then `cd analysis && ../.tools/bin/uv run python -m
  stt_analysis.comparison_chart_gen`
- Files to wire: see Playbook Appendix B.
