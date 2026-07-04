# OxCaml Epoll Performance Plan

This branch carries an experimental no-Async OxCaml gateway intended to test
whether removing Async scheduler/runtime overhead can move the 1-vCPU gateway
toward the Java virtual-thread result.

## Current Measured Candidate

- Variant: `ocaml-oxcaml-epoll`
- Entry point: `services/ocaml-oxcaml-epoll`
- k3s service/deployment: `stt-ocaml-oxcaml-epoll-gateway`
- Port: `9200`
- First fixed point: `2200` sessions
- Official runner: `scripts/bench/oxcaml_epoll_onechange.sh`
- Approval-gated k3s lifecycle wrapper:
  `scripts/bench/oxcaml_epoll_k3s_point.sh`

Applied local changes for the first k3s measurement:

- New single-loop Linux epoll gateway, separate from the accepted Async
  `services/ocaml-oxcaml` implementation.
- Explicit nonblocking WebSocket and HTTP/1.1 inference state machines.
- Reusable connection, PCM, response, timer, and inference buffers.
- Fixed 640-byte masked binary frame hot path.
- Direct JSON/WebSocket/inference request writers for the hot path.
- `epoll_ctl` C stub does not release/reacquire the OCaml runtime. This is a
  focused hot-path overhead reduction for add/mod/del calls.
- The ad hoc epoll deploy helper pins the gateway pod to
  `kubernetes.io/arch=amd64`, matching the single-architecture image built by
  `.github/workflows/images.yml` and avoiding accidental scheduling on the
  arm64 Jetson node.

Deliberately not applied yet:

- Removing runtime release/reacquire around `epoll_wait`. That may be a valid
  follow-up in this single-loop binary, but it must be measured separately from
  the `epoll_ctl` change.
- A second inference loop/thread. Add it only if k3s evidence shows timer
  lateness or inference completion bursts in the single-loop variant.
- Benchmark headline or graph updates. Those require repeat-confirmed k3s
  brackets.

## Acceptance Rules

- Use the official harness timing and SLO gates unchanged.
- Start at `2200` sessions. Probe upward only after a clean pass.
- Repeat any pass before treating it as a confirmed point.
- Preserve `protocol_errors=0`, `inference_errors=0`, and zero loadgen
  timeouts.
- Do not accept a change that materially worsens `flush_lateness.p95_ms`.
- Store run artifacts under `results/oxcaml-onechange-<timestamp>/`.
  Metadata and the experiments index record both the requested gateway image
  tag and the live gateway pod image digest.
- Reject `GATEWAY_REPLICAS` values other than `1` before mutating the cluster.
- Confirm the epoll Deployment reports exactly one desired replica and one
  ready replica before measuring.
- Confirm the epoll Deployment template and live gateway pod image match the
  requested experiment image tag before measuring.
- Confirm the epoll gateway pod schedules on an `amd64` node before measuring.
- The lifecycle wrapper scales `stt-inference-server` to `4`, applies one
  epoll gateway replica, verifies one desired/ready gateway replica, verifies
  the live Deployment/pod image, verifies the live gateway pod is scheduled on
  an `amd64` node, runs one official point, and scales both back to zero on
  exit.
  If the official point fails, the wrapper still cleans up and returns the
  benchmark command's nonzero status.

## Local Gates

Run these before publishing or deploying a new epoll image:

```bash
just oxcaml-epoll-portable-test
just oxcaml-epoll-check
just oxcaml-epoll-conformance
just oxcaml-epoll-smoke
just oxcaml-epoll-preflight
```

The smoke target is only a crash/protocol sanity check. It is not capacity
evidence.
The preflight helper defaults to the current commit's workflow-published
`ghcr.io/cezarc1/websocket-stt-bench/ocaml-oxcaml-epoll:sha-<shortsha>` image
tag; pass an explicit image only when intentionally measuring a different
published tag. Default-image mode requires a clean worktree and pushed `HEAD`
because the tag is built by GitHub Actions from the remote branch. Explicit
image mode reports the source commit, upstream commit, and worktree state for
traceability.
