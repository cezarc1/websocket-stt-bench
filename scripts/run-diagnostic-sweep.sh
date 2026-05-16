#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ROOT="$(repo_root)"
cd "$ROOT"

RUN_NAME="diagnostic-$(date +%Y%m%d-%H%M%S)"
OUT_DIR=""
RUNS_SUBDIR="runs"
DIAGNOSTIC_WARMUP_SECS=10
DIAGNOSTIC_MEASURE_SECS=45
STRESS_WARMUP_SECS=5
STRESS_MEASURE_SECS=20
RAMP_UP_SECS=0
SESSION_START_SPREAD_MS=0
REPEATS=1
PAUSE_SECS=5
ANALYZE=1
MAX_ERROR_RATE="0.00001"
PYTHON_STRESS=0
RUN_DEFAULT_MATRIX=1
MATRIX="scaling-2cpu"
MULTI_CPUS=2
MULTI_MEM_LIMIT="2g"
CUSTOM_POINTS=()
COMPOSE_ARGS=(-f docker-compose.yml)
INFERENCE_URL=""
RUST_INFERENCE_HTTP_CLIENTS=""

usage() {
  cat <<'USAGE'
Usage: scripts/run-diagnostic-sweep.sh [options]

Runs a short one-service-at-a-time diagnostic load sweep with paired summary
JSON, raw sample CSV, resource CSV, and raw loadgen logs.

Options:
  --out DIR                 Results directory. Default: results/diagnostic-<timestamp>
  --repeats N               Repeats per point. Default: 1
  --warmup-secs N           Warmup seconds for diagnostic points. Default: 10
  --measure-secs N          Measured seconds for diagnostic points. Default: 45
  --ramp-up-secs N          Linearly admit sessions over N seconds. Default: 0
  --session-start-spread-ms N
                            Add deterministic per-session start offsets across
                            N milliseconds. Use 1000 to de-phase 1000ms flushes.
                            Default: 0
  --stress-warmup-secs N    Warmup seconds for Python 500-session stress. Default: 5
  --stress-measure-secs N   Measured seconds for Python 500-session stress. Default: 20
  --pause-secs N            Pause between points. Default: 5
  --point SERVICE:S[,S...]  Run custom service/session points instead of the
                            default matrix. Can be passed multiple times.
  --matrix NAME             Default matrix to run: scaling-2cpu or diagnostic.
                            Default: scaling-2cpu
  --multi-cpus N            CPU count applied to *-multi services by an override
                            file for this sweep. Default: 2
  --multi-mem-limit LIMIT   Memory limit applied to *-multi services by the
                            override file. Default: 2g
  --inference-url URL       Use an already-running inference server instead of
                            the Compose-local inference-server service. Example:
                            http://192.0.2.10:30900
  --rust-inference-http-clients N
                            Override INFERENCE_HTTP_CLIENTS for rust-axum-* services.
                            Useful for testing HTTP/2 connection fanout.
  --no-python-stress        Skip the short 500-session Python stress points
  --python-stress           Include the short 500-session Python stress points
  --no-analyze              Skip running the analyzer at the end
  --max-error-rate RATE     Also write budgeted SLO analysis with this error
                            budget. Default: 0.00001. Use 0 for strict only.
  -h, --help                Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --repeats)
      REPEATS="$2"
      shift 2
      ;;
    --warmup-secs)
      DIAGNOSTIC_WARMUP_SECS="$2"
      shift 2
      ;;
    --measure-secs)
      DIAGNOSTIC_MEASURE_SECS="$2"
      shift 2
      ;;
    --ramp-up-secs)
      RAMP_UP_SECS="$2"
      shift 2
      ;;
    --session-start-spread-ms)
      SESSION_START_SPREAD_MS="$2"
      shift 2
      ;;
    --stress-warmup-secs)
      STRESS_WARMUP_SECS="$2"
      shift 2
      ;;
    --stress-measure-secs)
      STRESS_MEASURE_SECS="$2"
      shift 2
      ;;
    --pause-secs)
      PAUSE_SECS="$2"
      shift 2
      ;;
    --point)
      CUSTOM_POINTS+=("$2")
      RUN_DEFAULT_MATRIX=0
      PYTHON_STRESS=0
      shift 2
      ;;
    --matrix)
      MATRIX="$2"
      case "$MATRIX" in
        scaling-2cpu|diagnostic) ;;
        *)
          echo "--matrix must be scaling-2cpu or diagnostic, got $MATRIX" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --multi-cpus)
      MULTI_CPUS="$2"
      shift 2
      ;;
    --multi-mem-limit)
      MULTI_MEM_LIMIT="$2"
      shift 2
      ;;
    --inference-url|--remote-inference-url)
      INFERENCE_URL="${2%/}"
      shift 2
      ;;
    --rust-inference-http-clients)
      RUST_INFERENCE_HTTP_CLIENTS="$2"
      shift 2
      ;;
    --no-python-stress)
      PYTHON_STRESS=0
      shift
      ;;
    --python-stress)
      PYTHON_STRESS=1
      shift
      ;;
    --no-analyze)
      ANALYZE=0
      shift
      ;;
    --max-error-rate)
      MAX_ERROR_RATE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="results/$RUN_NAME"
fi

if ! [[ "$MULTI_CPUS" =~ ^[1-9][0-9]*$ ]]; then
  echo "--multi-cpus must be a positive integer because runtime worker counts use it" >&2
  exit 2
fi
if [[ -n "$RUST_INFERENCE_HTTP_CLIENTS" ]] && ! [[ "$RUST_INFERENCE_HTTP_CLIENTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "--rust-inference-http-clients must be a positive integer" >&2
  exit 2
fi

RUNS_DIR="$OUT_DIR/$RUNS_SUBDIR"
ANALYSIS_DIR="$OUT_DIR/analysis"
ANALYSIS_STRICT_DIR="$OUT_DIR/analysis-strict"
mkdir -p "$RUNS_DIR"

write_multi_profile_override() {
  local override="$OUT_DIR/compose-${MULTI_CPUS}vcpu.override.yml"
  cat > "$override" <<YAML
services:
  python-fastapi-stock-multi:
    cpus: ${MULTI_CPUS}
    mem_limit: ${MULTI_MEM_LIMIT}
    environment:
      WORKER_THREADS: "${MULTI_CPUS}"

  python-fastapi-stock-gil-multi:
    cpus: ${MULTI_CPUS}
    mem_limit: ${MULTI_MEM_LIMIT}
    environment:
      WORKER_THREADS: "${MULTI_CPUS}"

  python-fastapi-mt-multi:
    cpus: ${MULTI_CPUS}
    mem_limit: ${MULTI_MEM_LIMIT}
    environment:
      WORKER_THREADS: "${MULTI_CPUS}"
      GRANIAN_LOOPS: "${MULTI_CPUS}"

  elixir-phoenix-multi:
    cpus: ${MULTI_CPUS}
    mem_limit: ${MULTI_MEM_LIMIT}
    environment:
      WORKER_THREADS: "${MULTI_CPUS}"

  rust-axum-multi:
    cpus: ${MULTI_CPUS}
    mem_limit: ${MULTI_MEM_LIMIT}
    environment:
      WORKER_THREADS: "${MULTI_CPUS}"
YAML
  COMPOSE_ARGS=(-f docker-compose.yml -f "$override")
}

write_remote_inference_override() {
  if [[ -z "$INFERENCE_URL" ]]; then
    return 0
  fi

  local override="$OUT_DIR/compose-remote-inference.override.yml"
  cat > "$override" <<YAML
services:
  python-fastapi-stock-single:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
  python-fastapi-stock-multi:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
  python-fastapi-stock-gil-single:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
  python-fastapi-stock-gil-multi:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
  python-fastapi-mt-single:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
  python-fastapi-mt-multi:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
  elixir-phoenix-single:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
  elixir-phoenix-multi:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
  rust-axum-single:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
  rust-axum-multi:
    environment:
      INFERENCE_URL: "${INFERENCE_URL}"
YAML
  COMPOSE_ARGS+=(-f "$override")
}

write_rust_inference_clients_override() {
  if [[ -z "$RUST_INFERENCE_HTTP_CLIENTS" ]]; then
    return 0
  fi

  local override="$OUT_DIR/compose-rust-inference-clients.override.yml"
  cat > "$override" <<YAML
services:
  rust-axum-single:
    environment:
      INFERENCE_HTTP_CLIENTS: "${RUST_INFERENCE_HTTP_CLIENTS}"
  rust-axum-multi:
    environment:
      INFERENCE_HTTP_CLIENTS: "${RUST_INFERENCE_HTTP_CLIENTS}"
YAML
  COMPOSE_ARGS+=(-f "$override")
}

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

write_multi_profile_override
write_remote_inference_override
write_rust_inference_clients_override

printf '%s\n' "${INFERENCE_URL:-local-compose-inference-server}" > "$OUT_DIR/inference-target.txt"
if [[ -n "$RUST_INFERENCE_HTTP_CLIENTS" ]]; then
  printf 'rust_inference_http_clients=%s\n' "$RUST_INFERENCE_HTTP_CLIENTS" > "$OUT_DIR/runtime-overrides.txt"
fi

check_remote_inference() {
  if [[ -z "$INFERENCE_URL" ]]; then
    return 0
  fi

  echo "==> Checking remote inference server at ${INFERENCE_URL}/health"
  if ! curl -fsS "${INFERENCE_URL}/health" >/dev/null; then
    echo "remote inference server did not pass health check: ${INFERENCE_URL}/health" >&2
    return 1
  fi
}

down_all() {
  compose --profile loadgen --profile single --profile multi down --remove-orphans >/dev/null
}

cleanup() {
  down_all || true
}
trap cleanup EXIT

profile_for_service() {
  case "$1" in
    *-single) echo "single" ;;
    *-multi) echo "multi" ;;
    *)
      echo "cannot infer compose profile for service $1" >&2
      return 1
      ;;
  esac
}

service_port() {
  case "$1" in
    rust-axum-*) echo "3000" ;;
    elixir-phoenix-*) echo "4000" ;;
    python-fastapi-*) echo "8000" ;;
    *)
      echo "cannot infer service port for $1" >&2
      return 1
      ;;
  esac
}

host_health_port() {
  case "$1" in
    rust-axum-*) echo "3001" ;;
    elixir-phoenix-*) echo "4001" ;;
    python-fastapi-stock-gil-*) echo "8003" ;;
    python-fastapi-stock-*) echo "8001" ;;
    python-fastapi-mt-*) echo "8002" ;;
    *)
      echo "cannot infer host health port for $1" >&2
      return 1
      ;;
  esac
}

wait_for_health() {
  local service="$1"
  local host_port
  host_port="$(host_health_port "$service")"
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${host_port}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "service $service did not become healthy on host port $host_port" >&2
  if [[ -n "$INFERENCE_URL" ]]; then
    compose logs --tail=160 "$service" >&2 || true
  else
    compose logs --tail=160 "$service" inference-server >&2 || true
  fi
  return 1
}

start_service() {
  local service="$1"
  local profile
  profile="$(profile_for_service "$service")"

  echo
  echo "==> Starting $service ($profile profile)"
  down_all
  local up_args=(--profile "$profile" up -d --no-build)
  if [[ -n "$INFERENCE_URL" ]]; then
    up_args+=(--no-deps)
  fi
  up_args+=("$service")
  compose "${up_args[@]}"
  wait_for_health "$service"
}

compact_summary() {
  local summary="$1"
  python3 - "$summary" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text())
timeouts = payload.get("timeouts", {})
timeout_total = sum(int(value) for value in timeouts.values())
newest = payload["newest_frame_to_partial_latency"]
oldest = payload["oldest_frame_to_partial_latency"]
print(
    "    partials={partials} protocol_errors={protocol_errors} "
    "inference_errors={inference_errors} timeouts={timeouts} "
    "newest_p50={newest_p50:.1f}ms newest_p95={newest_p95:.1f}ms "
    "oldest_p50={oldest_p50:.1f}ms oldest_p95={oldest_p95:.1f}ms".format(
        partials=payload.get("partials", 0),
        protocol_errors=payload.get("protocol_errors", 0),
        inference_errors=payload.get("inference_errors", 0),
        timeouts=timeout_total,
        newest_p50=float(newest["p50_ms"]),
        newest_p95=float(newest["p95_ms"]),
        oldest_p50=float(oldest["p50_ms"]),
        oldest_p95=float(oldest["p95_ms"]),
    )
)
PY
}

extract_summary_json() {
  local raw_log="$1"
  local summary_json="$2"
  awk '
    BEGIN { started = 0 }
    /^\{/ { started = 1 }
    started { print }
  ' "$raw_log" > "$summary_json"
  python3 -m json.tool "$summary_json" >/dev/null
}

stop_sampler() {
  local sampler_pid="${1:-}"
  if [[ -n "$sampler_pid" ]] && kill -0 "$sampler_pid" 2>/dev/null; then
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
  fi
}

run_point() {
  local service="$1"
  local sessions="$2"
  local warmup_secs="$3"
  local measure_secs="$4"
  local repeat="$5"
  local port
  local base
  local container_id
  local inference_container_id=""
  local sampler_pid=""
  local inference_sampler_pid=""
  local loadgen_container_id=""
  local loadgen_pid=""
  local loadgen_sampler_pid=""

  port="$(service_port "$service")"
  local load_shape_suffix=""
  if [[ "$RAMP_UP_SECS" != "0" || "$SESSION_START_SPREAD_MS" != "0" ]]; then
    load_shape_suffix="-${RAMP_UP_SECS}ramp-${SESSION_START_SPREAD_MS}spread"
  fi
  base="$RUNS_DIR/${service}-${sessions}s-${warmup_secs}w-${measure_secs}m${load_shape_suffix}-r${repeat}"

  if [[ -s "${base}.summary.json" && -s "${base}.samples.csv" ]]; then
    echo "==> Skipping existing ${base}.summary.json"
    return 0
  fi

  echo "==> $service sessions=$sessions warmup=${warmup_secs}s measure=${measure_secs}s repeat=$repeat"
  container_id="$(compose ps -q "$service")"
  if [[ -z "$container_id" ]]; then
    echo "no running container found for $service" >&2
    return 1
  fi
  if [[ -z "$INFERENCE_URL" ]]; then
    inference_container_id="$(compose ps -q inference-server)"
    if [[ -z "$inference_container_id" ]]; then
      echo "no running container found for inference-server" >&2
      return 1
    fi
  fi

  python3 scripts/sample-docker-stats.py \
    --out "${base}.resources.csv" \
    --interval-secs 1 \
    "$container_id" &
  sampler_pid="$!"
  if [[ -n "$inference_container_id" ]]; then
    python3 scripts/sample-docker-stats.py \
      --out "${base}.inference.resources.csv" \
      --interval-secs 1 \
      "$inference_container_id" &
    inference_sampler_pid="$!"
  fi

  compose --profile loadgen run --rm --no-deps loadgen \
    --url "ws://${service}:${port}/ws/stt" \
    --service-name "$service" \
    --sessions "$sessions" \
    --warmup-secs "$warmup_secs" \
    --measure-secs "$measure_secs" \
    --ramp-up-secs "$RAMP_UP_SECS" \
    --session-start-spread-ms "$SESSION_START_SPREAD_MS" \
    --repeat "$repeat" \
    --samples-out "/results/${OUT_DIR#results/}/${RUNS_SUBDIR}/${service}-${sessions}s-${warmup_secs}w-${measure_secs}m${load_shape_suffix}-r${repeat}.samples.csv" \
    > "${base}.loadgen.raw.log" 2>&1 &
  loadgen_pid="$!"

  for _ in $(seq 1 10); do
    loadgen_container_id="$(
      docker ps \
        --filter "label=com.docker.compose.service=loadgen" \
        --format "{{.ID}}" \
        | tail -n 1
    )"
    if [[ -n "$loadgen_container_id" ]]; then
      break
    fi
    sleep 1
  done
  if [[ -n "$loadgen_container_id" ]]; then
    python3 scripts/sample-docker-stats.py \
      --out "${base}.loadgen.resources.csv" \
      --interval-secs 1 \
      "$loadgen_container_id" &
    loadgen_sampler_pid="$!"
  else
    echo "warning: could not find loadgen container to sample resources" >&2
  fi

  set +e
  wait "$loadgen_pid"
  local loadgen_status=$?
  set -e

  stop_sampler "$sampler_pid"
  stop_sampler "$inference_sampler_pid"
  stop_sampler "$loadgen_sampler_pid"

  if ! extract_summary_json "${base}.loadgen.raw.log" "${base}.summary.json"; then
    echo "failed to extract summary JSON from ${base}.loadgen.raw.log" >&2
    tail -80 "${base}.loadgen.raw.log" >&2 || true
    return 1
  fi
  compact_summary "${base}.summary.json"

  if [[ "$loadgen_status" -ne 0 ]]; then
    echo "loadgen exited with status $loadgen_status; keeping artifacts for diagnostics" >&2
    return "$loadgen_status"
  fi
}

run_service_points() {
  local service="$1"
  shift
  start_service "$service"
  local session_count
  local repeat
  for session_count in "$@"; do
    for repeat in $(seq 1 "$REPEATS"); do
      if ! run_point "$service" "$session_count" "$DIAGNOSTIC_WARMUP_SECS" "$DIAGNOSTIC_MEASURE_SECS" "$repeat"; then
        echo "warning: point failed for $service at $session_count sessions; continuing" >&2
      fi
      sleep "$PAUSE_SECS"
    done
  done
}

run_python_stress_points() {
  local service
  local repeat
  for service in \
    python-fastapi-stock-single \
    python-fastapi-stock-multi \
    python-fastapi-mt-single \
    python-fastapi-mt-multi
  do
    start_service "$service"
    for repeat in $(seq 1 "$REPEATS"); do
      if ! run_point "$service" 500 "$STRESS_WARMUP_SECS" "$STRESS_MEASURE_SECS" "$repeat"; then
        echo "warning: stress point failed for $service; continuing" >&2
      fi
      sleep "$PAUSE_SECS"
    done
  done
}

run_custom_points() {
  local spec
  local service
  local sessions_csv
  local sessions

  for spec in "${CUSTOM_POINTS[@]}"; do
    if [[ "$spec" != *:* ]]; then
      echo "--point expects SERVICE:S[,S...] but got $spec" >&2
      return 2
    fi
    service="${spec%%:*}"
    sessions_csv="${spec#*:}"
    IFS=, read -r -a sessions <<< "$sessions_csv"
    run_service_points "$service" "${sessions[@]}"
  done
}

run_diagnostic_matrix() {
  run_service_points rust-axum-single 200 225
  run_service_points rust-axum-multi 200 225
  run_service_points elixir-phoenix-single 200 225
  run_service_points elixir-phoenix-multi 200 225

  run_service_points python-fastapi-stock-single 150 175 200
  run_service_points python-fastapi-stock-multi 100 125 150
  run_service_points python-fastapi-mt-single 125 150 175
  run_service_points python-fastapi-mt-multi 100 125 150
}

run_scaling_2cpu_matrix() {
  # Current tuned 1-vCPU anchors:
  #   Rust 1900 pass / 1950 fail
  #   Elixir 700 pass / 725 fail
  #   Python free-threaded mt-single 175-ish edge from prior runs
  # Multi-profile points jump straight near the expected 2x region, with one
  # conservative point below it and one point just above it where practical.
  run_service_points rust-axum-single 1900 1950
  run_service_points rust-axum-multi 3400 3800 4000

  run_service_points elixir-phoenix-single 700 725
  run_service_points elixir-phoenix-multi 1200 1400 1500

  run_service_points python-fastapi-mt-single 175 200
  run_service_points python-fastapi-mt-multi 175 225 250 275
}

echo "Writing diagnostic sweep artifacts to $OUT_DIR"
echo "Matrix: $MATRIX"
echo "Diagnostic points: warmup=${DIAGNOSTIC_WARMUP_SECS}s measure=${DIAGNOSTIC_MEASURE_SECS}s repeats=$REPEATS pause=${PAUSE_SECS}s"
echo "Load shape: ramp_up=${RAMP_UP_SECS}s session_start_spread=${SESSION_START_SPREAD_MS}ms"
echo "Multi profile override: cpus=${MULTI_CPUS} mem_limit=${MULTI_MEM_LIMIT}"
if [[ -n "$RUST_INFERENCE_HTTP_CLIENTS" ]]; then
  echo "Rust inference HTTP clients override: ${RUST_INFERENCE_HTTP_CLIENTS}"
fi
if [[ -n "$INFERENCE_URL" ]]; then
  echo "Inference target: remote ${INFERENCE_URL}"
else
  echo "Inference target: Compose-local inference-server"
fi
if [[ "$PYTHON_STRESS" -eq 1 ]]; then
  echo "Python stress points: sessions=500 warmup=${STRESS_WARMUP_SECS}s measure=${STRESS_MEASURE_SECS}s"
fi

check_remote_inference

if [[ "$RUN_DEFAULT_MATRIX" -eq 1 ]]; then
  case "$MATRIX" in
    scaling-2cpu) run_scaling_2cpu_matrix ;;
    diagnostic) run_diagnostic_matrix ;;
  esac
else
  run_custom_points
fi

if [[ "$PYTHON_STRESS" -eq 1 ]]; then
  run_python_stress_points
fi

down_all

if [[ "$ANALYZE" -eq 1 ]]; then
  echo
  echo "==> Running strict-zero analyzer"
  just analyze-results-slo-budget \
    "$RUNS_DIR" \
    "$ANALYSIS_STRICT_DIR" \
    0 \
    balanced-realtime \
    "$MULTI_CPUS"
  if [[ "$MAX_ERROR_RATE" != "0" && "$MAX_ERROR_RATE" != "0.0" ]]; then
    echo
    echo "==> Running budgeted analyzer (max_error_rate=$MAX_ERROR_RATE)"
    just analyze-results-slo-budget \
      "$RUNS_DIR" \
      "$ANALYSIS_DIR" \
      "$MAX_ERROR_RATE" \
      balanced-realtime \
      "$MULTI_CPUS"
  fi
fi

printf '%s\n' "$OUT_DIR" > results/.last-diagnostic-sweep-dir
echo
echo "Done: $OUT_DIR"
