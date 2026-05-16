# Repository Guidelines

## Project Structure & Module Organization

This repo benchmarks streaming STT gateways behind one WebSocket protocol. Root orchestration: `justfile`, `docker-compose.yml`, `versions.lock.toml`, `docker/`, `scripts/`, and `results/`. Gateway services live in `services/rust-axum/src`, `services/go-nethttp`, `services/typescript-bun/src`, `services/python-fastapi/app`, `services/elixir-phoenix/lib`, and `services/ocaml-oxcaml/{lib,bin,test}`; the shared Rust inference compute is in `services/inference-server/src`; the Rust load generator is in `loadgen/rust`. Current tests live beside each service (`services/go-nethttp/internal/**`, `services/typescript-bun/tests`, `services/elixir-phoenix/test`, `services/ocaml-oxcaml/test`); add Rust tests near crate code and Python tests under `services/python-fastapi/tests`.

## Build, Test, and Development Commands

- `just doctor`: install pinned local `uv`, Bun, and Go, then verify Python, Elixir/OTP, Rust, Docker, and cargo plugin versions.
- `just py-sync`: sync the FastAPI virtualenv from `uv.lock`.
- `just check`: run the full gate across doctor, Python, TypeScript/Bun, Go, Elixir, and Rust checks.
- `just python-check`, `just ts-check`, `just go-check`, `just elixir-check`, `just rust-check`, `just ocaml-check`: run focused validation while iterating. `ocaml-check` requires the OxCaml switch — `just ensure-oxcaml-switch` (slow first run: ~15-20 min to build the OxCaml compiler from source).
- `just compose-build`, `just compose-single`, `just compose-multi`: build and run Docker services.
- `just conformance`: build images, start the single-profile services, and run the black-box WebSocket protocol conformance suite from the loadgen image.
- `just bench-ladder rust-axum-single ws://127.0.0.1:3000/ws/stt`: run the load ladder and write paired summary JSON and raw sample CSV files to `results/`.
- `just analyze-results results/initial results/initial/analysis`: analyze paired result files and write CSV, Markdown, and PNG summaries.

## Reliable Load-Test Workflow

Build and verify before measuring: run `just check`, `just compose-build`, and `just conformance`, then start only one Compose profile at a time. The `single` and `multi` profiles share host ports, so always run `docker compose --profile single down` before starting `multi`, and vice versa. Prefer container-to-container loadgen URLs such as `ws://rust-axum-single:3000/ws/stt`; avoid host-port URLs for Compose benchmarks unless you are intentionally measuring host networking.

`just conformance` checks the strict contract across Rust, Go, TypeScript/Bun, Elixir, and both Python single-profile services: required `partial` schema, deterministic one-frame stub output, invalid start close code `1002`, invalid frame close code `1003`, flush cadence tolerance, and prompt normal close behavior. Fix conformance failures before trusting benchmark results.

For a fast smoke run, use `results/initial/`, `50` sessions, `5s` warmup, `15s` measured, and one repeat for Rust/Elixir. Python showed saturation at the 50-session point in the initial run, so use `10` sessions, `3s` warmup, `10s` measured for Python smoke baselines until that behavior is fixed. Name files as `<service>-<sessions>s-<warmup>w-<measure>m-r<repeat>.summary.json` and `<service>-<sessions>s-<warmup>w-<measure>m-r<repeat>.samples.csv`, for example `results/initial/rust-axum-single-50s-5w-15m-r1.summary.json`.

Loadgen has explicit connect, send, close-grace, and whole-session timeouts and reports them under `.timeouts` in the JSON output. When a loadgen run still stalls after the measured window, stop only the loadgen container, do not include empty or partial result files in summaries, and report the point as saturated or failed to complete. Always tear down Compose services after a benchmark with `docker compose --profile <profile> down`, and check `docker ps` before finishing so no benchmark containers are left running.

## Adding a New Runtime/Language

Adding or re-measuring a gateway follows a fixed, reproducible procedure — see **`docs/RUNTIME_PLAYBOOK.md`** (or invoke the `add-runtime` skill). It runs end to end: plan (with approval) → implement to the shared black-box protocol → `just conformance` (hard gate) → `/simplify` + re-verify → CI image → cluster deploy + smoke → 1-vCPU then 2-vCPU divide-and-conquer ceiling → succinct `README.md` + regenerated `docs/loc-vs-capacity.png` → PR. Capacity is measured only with the tracked harness `scripts/bench/{run_point,ladder,eval_slo}`; its pod shape, timings, SLO gates, and `confirmed ↔ borderline ↔ first-solid-fail` bracketing are the comparability contract and must not be tuned per-runtime. The agent works autonomously except at the `[ASK]` gates (plan approval, protocol ambiguity, push/CI-dispatch/cluster-scale/PR). Every runtime ships an **Agent Build Log** (autonomous-debug iterations, where human input was needed, a 1–5 agent-debuggability score) — a first-class result alongside perf and LOC.

## Coding Style & Naming Conventions

Keep pinned versions in `versions.lock.toml`. Rust uses edition 2024, `rustfmt`, and `cargo clippy -- -D warnings`; prefer snake_case modules, functions, and fields. Go uses `gofumpt`, `goimports`, `go vet`, `golangci-lint`, `govulncheck`, and idiomatic package-local tests. Python targets CPython 3.14 free-threading, Ruff with 100-character lines, and typed async WebSocket code. Elixir uses `mix format`, Credo strict mode, Dialyzer, and `SttGateway.*` module names. Do not commit `.tools/`, `target/`, `.venv/`, `_build/`, `deps/`, `results/` outputs, logs, dumps, or `__pycache__/`.

## Testing & Agent Self-Verification

Before claiming work is complete, inspect the diff and run the narrowest relevant check; use `just check` for cross-language or release-facing changes. The focused gates are explicit: Python and analysis projects run `ruff format --check`, `ruff check`, `ty check`, and pytest; Go runs `gofumpt`, `goimports`, `go mod tidy -diff`, `go vet`, `golangci-lint`, `govulncheck`, `go test`, and `go test -race`; Elixir runs `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, and `mix test`; Rust runs `cargo fmt --check`, `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`, `cargo nextest run --workspace --all-features --locked`, and `cargo deny check`. Report skipped checks and failures. Tests should validate protocol behavior and deterministic STT stub output. Name Elixir tests `*_test.exs`; use Rust unit/integration tests, Go `*_test.go` files, and Python `test_*.py` files.

## Commit & Pull Request Guidelines

This repository has no existing commits, so no local convention is established. Use short imperative subjects such as `Add FastAPI latency metrics` and keep unrelated changes separate. PRs should describe the benchmark path affected, list validation commands run, note version or lockfile changes, and include representative results when benchmark behavior changes.
