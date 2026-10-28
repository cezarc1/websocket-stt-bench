#!/usr/bin/env bash
# Fast local OxCaml diagnostic point.
#
# This is intentionally not a comparable benchmark harness. Use it to reject
# ideas quickly and inspect OXCAML_DIAG output before validating a candidate on
# k3s with run_point.sh / ladder.sh.
#
#   scripts/bench/oxcaml_local_diag.sh <sessions> [warmup] [measure] [ramp] [spread]
#
# Optional env:
#   RESULTS_DIR              default: results/local-oxcaml-diag
#   PORT                     gateway port, default: 19000
#   INFERENCE_PORT           inference port, default: 19001
#   OXCAML_DIAG_INTERVAL_MS  default: 1000
#   OXCAML_DIAG_SAMPLE_EVERY default: 100
#   OXCAML_TRACE             default: 0
#   OXCAML_TRACE_FILE        default: <run>.trace.json when tracing is enabled
#   OXCAML_TRACE_SAMPLE_EVERY default: OXCAML_DIAG_SAMPLE_EVERY
#   OXCAML_TRACE_FLUSH_INTERVAL_MS default: 1000
#   OXCAML_TRACE_FRAME_SAMPLE_EVERY default: 500
#   OXCAML_TRACE_MAX_EVENTS   default: 200000
#   MODEL_DELAY_MS           default: 75
#   MODEL_BATCH_WAIT_MAX_MS  default: 20
#   CPU_PASSES               default: 4
#   ASYNC_CONFIG             optional Async runtime config for Linux/epoll runs
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SESS="${1:?usage: scripts/bench/oxcaml_local_diag.sh <sessions> [warmup measure ramp spread]}"
WARMUP="${2:-5}"
MEASURE="${3:-15}"
RAMP="${4:-0}"
SPREAD="${5:-0}"

RESULTS_DIR="${RESULTS_DIR:-$ROOT/results/local-oxcaml-diag}"
PORT="${PORT:-19000}"
INFERENCE_PORT="${INFERENCE_PORT:-19001}"
OXCAML_DIAG_INTERVAL_MS="${OXCAML_DIAG_INTERVAL_MS:-1000}"
OXCAML_DIAG_SAMPLE_EVERY="${OXCAML_DIAG_SAMPLE_EVERY:-100}"
OXCAML_TRACE="${OXCAML_TRACE:-0}"
OXCAML_TRACE_SAMPLE_EVERY="${OXCAML_TRACE_SAMPLE_EVERY:-$OXCAML_DIAG_SAMPLE_EVERY}"
OXCAML_TRACE_FLUSH_INTERVAL_MS="${OXCAML_TRACE_FLUSH_INTERVAL_MS:-1000}"
OXCAML_TRACE_FRAME_SAMPLE_EVERY="${OXCAML_TRACE_FRAME_SAMPLE_EVERY:-500}"
MODEL_DELAY_MS="${MODEL_DELAY_MS:-75}"
MODEL_BATCH_WAIT_MAX_MS="${MODEL_BATCH_WAIT_MAX_MS:-20}"
CPU_PASSES="${CPU_PASSES:-4}"
ASYNC_CONFIG="${ASYNC_CONFIG:-}"

SWITCH="$(awk -F\" '/oxcaml_switch =/{print $2; exit}' "$ROOT/versions.lock.toml")"
STAMP="$(date +%Y%m%dT%H%M%S)"
BASE="$RESULTS_DIR/ocaml-oxcaml-local-${SESS}s-${WARMUP}w-${MEASURE}m-r1-${STAMP}"
OXCAML_TRACE_FILE="${OXCAML_TRACE_FILE:-$BASE.trace.json}"

mkdir -p "$RESULTS_DIR"

INF_PID=""
GW_PID=""

cleanup() {
  if [ -n "$GW_PID" ] && kill -0 "$GW_PID" >/dev/null 2>&1; then
    kill "$GW_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$INF_PID" ] && kill -0 "$INF_PID" >/dev/null 2>&1; then
    kill "$INF_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_http() {
  local url="$1"
  local deadline=$(( $(date +%s) + 20 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "timed out waiting for $url" >&2
  return 1
}

wait_for_tcp() {
  local port="$1"
  local deadline=$(( $(date +%s) + 20 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "timed out waiting for 127.0.0.1:$port" >&2
  return 1
}

echo "building local binaries..." >&2
cargo build --locked --release -p stt-inference-server -p stt-loadgen >/dev/null
(cd "$ROOT/services/ocaml-oxcaml" \
  && opam exec --switch "$SWITCH" -- dune build --profile release --root . >/dev/null)

echo "starting inference on :$INFERENCE_PORT" >&2
(
  cd "$ROOT"
  PORT="$INFERENCE_PORT" \
  MODEL_DELAY_MS="$MODEL_DELAY_MS" \
  MODEL_BATCH_WAIT_MAX_MS="$MODEL_BATCH_WAIT_MAX_MS" \
  CPU_PASSES="$CPU_PASSES" \
  ./target/release/stt-inference-server
) >"$BASE.inference.log" 2>&1 &
INF_PID="$!"
wait_for_http "http://127.0.0.1:$INFERENCE_PORT/health"

echo "starting OxCaml gateway on :$PORT with diagnostics" >&2
(
  cd "$ROOT"
  if [ -n "$ASYNC_CONFIG" ]; then
    export ASYNC_CONFIG
  fi
  PORT="$PORT" \
  INFERENCE_URL="http://127.0.0.1:$INFERENCE_PORT" \
  MODEL_DELAY_MS="$MODEL_DELAY_MS" \
  CPU_PASSES="$CPU_PASSES" \
  OXCAML_DIAG=1 \
  OXCAML_DIAG_INTERVAL_MS="$OXCAML_DIAG_INTERVAL_MS" \
  OXCAML_DIAG_SAMPLE_EVERY="$OXCAML_DIAG_SAMPLE_EVERY" \
  OXCAML_TRACE="$OXCAML_TRACE" \
  OXCAML_TRACE_FILE="$OXCAML_TRACE_FILE" \
  OXCAML_TRACE_SAMPLE_EVERY="$OXCAML_TRACE_SAMPLE_EVERY" \
  OXCAML_TRACE_FLUSH_INTERVAL_MS="$OXCAML_TRACE_FLUSH_INTERVAL_MS" \
  OXCAML_TRACE_FRAME_SAMPLE_EVERY="$OXCAML_TRACE_FRAME_SAMPLE_EVERY" \
  opam exec --switch "$SWITCH" -- ./services/ocaml-oxcaml/_build/default/bin/main.exe
) >"$BASE.gateway.stdout.log" 2>"$BASE.gateway.stderr.log" &
GW_PID="$!"
wait_for_tcp "$PORT"

echo "running loadgen: sessions=$SESS warmup=$WARMUP measure=$MEASURE" >&2
"$ROOT/target/release/stt-loadgen" \
  --url "ws://127.0.0.1:$PORT/ws/stt" \
  --service-name "ocaml-oxcaml-local-diag" \
  --sessions "$SESS" \
  --warmup-secs "$WARMUP" \
  --measure-secs "$MEASURE" \
  --ramp-up-secs "$RAMP" \
  --session-start-spread-ms "$SPREAD" \
  --repeat 1 \
  --samples-out "$BASE.samples.csv" \
  >"$BASE.loadgen.out"

awk '/^\{/{f=1} f' "$BASE.loadgen.out" >"$BASE.summary.json"

python3 "$ROOT/scripts/bench/eval_slo.py" "$SESS" <"$BASE.summary.json"
echo "summary=$BASE.summary.json" >&2
echo "samples=$BASE.samples.csv" >&2
echo "loadgen_log=$BASE.loadgen.out" >&2
echo "gateway_diag=$BASE.gateway.stderr.log" >&2
if [ "$OXCAML_TRACE" = "1" ]; then
  echo "gateway_trace=$OXCAML_TRACE_FILE" >&2
fi
