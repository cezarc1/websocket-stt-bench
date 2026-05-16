# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A comparative benchmark of streaming speech-to-text gateways implementing one shared WebSocket protocol across three runtimes:

- `services/rust-axum/` — Axum + Tokio gateway
- `services/python-fastapi/` — FastAPI on Granian gateway, CPython 3.14 free-threading
- `services/elixir-phoenix/` — Phoenix + Bandit gateway (`WebSock` adapter, no channels)
- `services/inference-server/` — shared deterministic compute (Rust + Axum). All three gateways POST batched PCM here over HTTP/2 instead of computing inline.
- `loadgen/rust/` — single Rust load generator that drives all three

The deterministic STT stub (FNV-1a checksum, RMS, zero crossings, plus a transcript word indexed by checksum) is now centralized: it runs in `services/inference-server/src/main.rs::compute_stub` and is the single source of truth for numeric outputs. A Python reimplementation in `services/python-fastapi/app/stub.py::compute_stub` exists *only* for cross-language parity tests under `services/python-fastapi/tests/`; nothing on the runtime path calls it. Numeric divergence between the inference server and that reference impl is a bug.

`AGENTS.md` is the canonical contributor guide; this file covers architecture decisions and gotchas that aren't obvious from the tree.

## Shared protocol contract

Every service must implement identical behavior at `/ws/stt`:

1. Client sends JSON `{"type":"start"}`.
2. Client streams 16 kHz mono PCM, 20 ms / **640 bytes** per binary frame.
3. Server buffers frames per-connection, flushes every **1000 ms**.
4. The gateway POSTs the concatenated PCM body to the inference server's `/infer` (HTTP/2, `x-cpu-passes` header). The inference server runs the CPU stub (`CPU_PASSES=4` default) and sleeps `MODEL_DELAY_MS` (default 75 ms) to simulate model inference, then returns a JSON envelope including `transcript`, `audio_bytes`, and the four numeric stats. The gateway forwards those fields plus its own timing/sequencing context as a `partial` JSON.
5. The `partial` payload **must** include `oldest_frame_seq`, `newest_frame_seq`, `flush_lateness_ms`, and `inflight_model_jobs` — the load generator depends on these to compute per-frame latency curves.
6. Invalid first messages close with WebSocket code `1002`. Invalid binary frame sizes close with code `1003`. Normal client close should finish promptly and must not require a final drained partial.

When changing the protocol, update all three services, `loadgen/rust/src/protocol.rs`, `loadgen/rust/src/main.rs`, and `loadgen/rust/src/bin/stt-conformance.rs` together.

The runtime-specific marshalling choices are intentional:

- Python uses Pydantic models in `services/python-fastapi/app/protocol.py` (`StartMessage`, `InferResponse`, `PartialMessage`).
- Elixir uses `SttGateway.Protocol.StartMessage` and `SttGateway.Protocol.PartialMessage` structs/helpers with built-in `JSON`.
- Rust uses serde structs in `services/rust-axum/src/protocol.rs` and shared serde models in the loadgen crate.

## Critical invariant: one in-flight inference request per connection

Each gateway bounds itself to **at most one in-flight inference request per WebSocket** so back-pressure shows up as growing oldest-frame latency rather than unbounded task spawning. Skipping this changes what the benchmark measures.

- Rust: `Semaphore::new(1)` + `try_acquire_owned()` in `services/rust-axum/src/session.rs::flush_loop`.
- Python: `SttSession.inflight` guards `_flush_loop` before scheduling `_process_batch` in `services/python-fastapi/app/session.py`.
- Elixir: `busy?` flag in `SttGatewayWeb.SttWebSocket.State` guards `do_flush/3` before starting the compute task.

If you add a new code path that spawns inference work per flush, preserve this guard.

## Versions are pinned, hard

`versions.lock.toml` is the source of truth. `scripts/doctor.sh` enforces exact versions of `just`, `uv`, Rust, Python (including `Py_GIL_DISABLED=1`), Elixir/OTP, and the cargo plugins.

- The repo ships its own pinned `uv` into `.tools/bin/` via `scripts/ensure-uv.sh` — always invoke uv as `.tools/bin/uv`, never the system one.
- Python is `3.14.4t` (free-threading). The FastAPI app aborts startup if `Py_GIL_DISABLED != 1` or `sys._is_gil_enabled()` is true (`services/python-fastapi/app/runtime.py::assert_runtime`). Don't relax that check.
- Rust uses edition 2024, `rust-version = "1.95.0"`, exact-version `=` constraints in `Cargo.toml`.
- Cargo workspace lives at the repo root and contains `loadgen/rust`, `services/rust-axum`, and `services/inference-server`.

When bumping a dependency, update `versions.lock.toml`, the relevant lockfile (`uv.lock`, `Cargo.lock`, `mix.lock`), and any version constants embedded in code (e.g. `AXUM_VERSION` / `TOKIO_VERSION` / `REQWEST_VERSION` in `services/rust-axum/src/config.rs`).

## Commands

Always prefer the focused per-language gate while iterating, then `just check` before claiming done.

- `just doctor` — verify toolchain matches `versions.lock.toml`, install pinned uv into `.tools/bin/`.
- `just check` — full gate: doctor + python-check + elixir-check + rust-check.
- `just python-check` — `ruff format --check`, `ruff check`, `ty check` (runs via `.tools/bin/uv run`).
- `just elixir-check` — `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix test`.
- `just rust-check` — `cargo fmt --check`, `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`, `cargo nextest run --workspace --all-features --locked`, `cargo deny check`.
- `just rust-tools` — install pinned `cargo-nextest` and `cargo-deny`. Required before first `rust-check`.
- `just py-lock` / `just py-sync` — regenerate or sync the FastAPI venv from `uv.lock`.
- `just compose-build` / `just compose-single` / `just compose-multi` — build images, run the `single` (1 CPU / 1 GB) or `multi` (4 CPU / 1 GB) profile.
- `just conformance` — build images, start the single-profile services, and run black-box protocol conformance from the loadgen image.
- `just bench-ladder SERVICE ws://HOST:PORT/ws/stt` — runs the 50→2000 session ladder (15 s warmup, 90 s measure, 3 repeats), writes paired `*.summary.json` and `*.samples.csv` files.
- `just analyze-results results/initial results/initial/analysis` — analyzes paired raw sample CSV and summary JSON files into CSV, Markdown, and PNG outputs.

Run a single Rust test: `cargo nextest run -p stt-loadgen payload_is_one_pcm_frame --locked`. Run a single Elixir test: `cd services/elixir-phoenix && mix test test/runtime_versions_test.exs`. Run analyzer tests with `just analysis-test`.

## Compose layout

`docker-compose.yml` defines eight service variants across two profiles:

- `single` profile (1 CPU, 1 GB): `python-fastapi-stock-single`, `python-fastapi-mt-single`, `elixir-phoenix-single`, `rust-axum-single`.
- `multi` profile (4 CPU, 1 GB): same four with `-multi` suffix and `WORKER_THREADS=4`.

Python ships two flavors per profile:
- **stock** = one asyncio loop; free-threading still benefits the in-process `ThreadPoolExecutor` sized by `WORKER_THREADS`.
- **mt** = Granian multi-loop, controlled by `GRANIAN_RUNTIME_THREADS`. This is the headline 3.14t configuration.

Port map: Rust `3001`, Python stock `8001`, Python mt `8002`, Elixir `4001`. The `loadgen` profile mounts `./results` and runs the load generator container; for local benches against host services use `just bench-ladder SERVICE ws://127.0.0.1:<port>/ws/stt`.

## Reliable load-test workflow

Use this sequence when asked to run benchmarks or validate load-test behavior:

1. Run `just check` unless the user explicitly asks for a quick run only.
2. Run `just compose-build` so every profiled image is built from the current checkout.
3. Run `just conformance` before collecting benchmark numbers.
4. Start exactly one profile with `docker compose --profile single up -d --no-build ...` or `docker compose --profile multi up -d --no-build ...`.
5. Run loadgen inside the Compose network with service DNS names, not host ports. Example: `ws://rust-axum-single:3000/ws/stt`.
6. Write every summary through `tee` and every raw sample CSV through `--samples-out` into `results/initial/` or another named subdirectory.
7. Tear down the active profile with `docker compose --profile <profile> down`.
8. Verify `docker ps` has no leftover `websocket-stt-bench-*` containers.

Do not run `single` and `multi` at the same time. They bind the same host ports. Start one, measure it, tear it down, then start the other.

The standard smoke point is:

- Rust and Elixir: `--sessions 50 --warmup-secs 5 --measure-secs 15 --repeat 1`.
- Python: start with `--sessions 10 --warmup-secs 3 --measure-secs 10 --repeat 1`. The first exploratory 50-session Python runs either saturated badly or stalled before producing JSON, so do not treat Python 50-session smoke as reliable until the server/loadgen behavior is revisited.

Name result files with all workload parameters: `<service>-<sessions>s-<warmup>w-<measure>m-r<repeat>.summary.json` and `<service>-<sessions>s-<warmup>w-<measure>m-r<repeat>.samples.csv`. Examples:

- `results/initial/rust-axum-single-50s-5w-15m-r1.summary.json`
- `results/initial/rust-axum-single-50s-5w-15m-r1.samples.csv`
- `results/initial/python-fastapi-mt-multi-10s-3w-10m-r1.summary.json`

Loadgen applies a 5 s connect timeout, 5 s send timeout, 5 s close grace, and 15 s whole-session grace by default. Output JSON includes `.timeouts.connect`, `.timeouts.send`, `.timeouts.close`, and `.timeouts.session`. If a loadgen run still does not return after the measured window plus the close/session grace, stop only the loadgen container with `docker rm -f <container>`, delete any empty JSON file, and report that point as failed to complete or saturated. Do not silently rerun at a different concurrency without saying why.

For summaries, report at least `sessions`, `partials`, `protocol_errors`, p99 newest-frame latency, p99 oldest-frame latency, and p99 flush lateness. This command gives a compact table:

```sh
for f in results/initial/*.summary.json results/initial/*.json; do
  [ -e "$f" ] || continue
  printf '%s ' "$(basename "$f")"
  jq -r '[.sessions,.partials,.protocol_errors,.timeouts.connect,.timeouts.send,.timeouts.close,.timeouts.session,.newest_frame_to_partial_latency.p99_ms,.oldest_frame_to_partial_latency.p99_ms,.flush_lateness.p99_ms] | @tsv' "$f"
done
```

## Load generator output

`loadgen/rust/src/main.rs` keeps a per-session `Vec<Instant>` indexed by sequence number, then on each typed `PartialMessage` looks up both `oldest_frame_seq` and `newest_frame_seq` to record two HDR histograms. This is why the server protocol must always emit both seq numbers — single-seq partials would break the oldest-frame latency curve. Output JSON contains P50/P95/P99/P999/max for `newest_frame_to_partial_latency`, `oldest_frame_to_partial_latency`, and `flush_lateness`, plus aggregate `protocol_errors` and timeout counters. When `--samples-out` is set, raw measured partial rows are also written to CSV and should be treated as the analysis source of truth.

## Conventions you'll likely trip over

- **Don't commit** `.tools/`, `target/`, `.venv/`, `_build/`, `deps/`, `results/` outputs, logs, dumps, `__pycache__/` (`.gitignore` covers them).
- Rust: snake_case modules/functions/fields, `cargo clippy -- -D warnings` is treated as the formatter for logic.
- Python: Ruff with 100-char line length, `target-version = "py314"`, lint set defaults + `I,UP,B,SIM,ASYNC,RUF,PERF,C4,PIE,RET,LOG,G,FA` (`services/python-fastapi/pyproject.toml`). Type-check with `ty`, not mypy.
- Elixir: `SttGateway.*` namespace; Credo runs in `--strict` mode; Dialyzer is part of the gate, so add `@spec` for new public functions.
