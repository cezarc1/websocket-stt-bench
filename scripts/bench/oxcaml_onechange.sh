#!/usr/bin/env bash
# Run one fixed OxCaml k3s experiment point and keep the evidence together.
#
# This is intentionally a thin wrapper around scripts/bench/run_point.sh. It
# does not change SLO gates, loadgen resources, pod shape, timing, flush
# cadence, close codes, or inference settings.
#
# Typical use:
#   CTX=cezar-4090-cluster \
#   LOADGEN_IMG=ghcr.io/cezarc1/websocket-stt-bench/loadgen:main \
#   EXPERIMENT_ID=E001-gc-s8388608 LABEL=oxcaml-e001-r1 \
#   scripts/bench/oxcaml_onechange.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SESS="${1:-${SESS:-2075}}"
WARMUP="${WARMUP:-10}"
MEASURE="${MEASURE:-45}"
RAMP="${RAMP:-30}"
SPREAD="${SPREAD:-1000}"

NS="${NS:-stt-bench}"
CTX="${CTX:-}"
SVC="${SVC:-stt-ocaml-oxcaml-gateway}"
PORT="${PORT:-9000}"
GATEWAY_DEPLOY="${GATEWAY_DEPLOY:-stt-ocaml-oxcaml-gateway}"
EXPERIMENT_ID="${EXPERIMENT_ID:-oxcaml-control}"
STAMP="${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
LABEL="${LABEL:-${EXPERIMENT_ID}-${STAMP}}"
RUN_DIR="${RUN_DIR:-$ROOT/results/oxcaml-onechange-${STAMP}}"
TOP_DELAY_SECS="${TOP_DELAY_SECS:-55}"

KCTX=()
[ -n "$CTX" ] && KCTX=(--context "$CTX")

PREFIX="${LABEL}-${SESS}"
mkdir -p "$RUN_DIR"

summary_file="$RUN_DIR/${PREFIX}.summary.json"
verdict_file="$RUN_DIR/${PREFIX}.verdict.txt"
metadata_file="$RUN_DIR/${PREFIX}.metadata.json"
cpu_before_file="$RUN_DIR/${PREFIX}.cpu.before.txt"
cpu_after_file="$RUN_DIR/${PREFIX}.cpu.after.txt"
cpu_delta_file="$RUN_DIR/${PREFIX}.cpu.delta.json"
top_file="$RUN_DIR/${PREFIX}.kubectl-top.txt"
pod_file="$RUN_DIR/${PREFIX}.pods.txt"
deploy_file="$RUN_DIR/${PREFIX}.gateway-deploy.yaml"
svc_file="$RUN_DIR/${PREFIX}.gateway-service.yaml"
git_status_file="$RUN_DIR/${PREFIX}.git-status.txt"
git_diffstat_file="$RUN_DIR/${PREFIX}.git-diffstat.txt"
index_file="$RUN_DIR/experiments.jsonl"

kubectl_cmd() {
  kubectl "${KCTX[@]}" "$@"
}

kubectl_ns() {
  kubectl_cmd -n "$NS" "$@"
}

capture_cpu_stat() {
  kubectl_ns exec "deploy/${GATEWAY_DEPLOY}" -- sh -lc \
    'cat /sys/fs/cgroup/cpu.stat' 2>&1
}

write_metadata() {
  local phase="$1"
  local gateway_image gateway_env git_rev git_branch git_dirty_count
  gateway_image="$(kubectl_ns get deploy "$GATEWAY_DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  gateway_env="$(kubectl_ns get deploy "$GATEWAY_DEPLOY" \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null || true)"
  git_rev="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
  git_branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
  git_dirty_count="$(git -C "$ROOT" status --short 2>/dev/null | wc -l | tr -d ' ')"

  PHASE="$phase" \
  ROOT="$ROOT" \
  RUN_DIR="$RUN_DIR" \
  EXPERIMENT_ID="$EXPERIMENT_ID" \
  STAMP="$STAMP" \
  LABEL="$LABEL" \
  PREFIX="$PREFIX" \
  SESS="$SESS" \
  WARMUP="$WARMUP" \
  MEASURE="$MEASURE" \
  RAMP="$RAMP" \
  SPREAD="$SPREAD" \
  NS="$NS" \
  CTX="$CTX" \
  SVC="$SVC" \
  PORT="$PORT" \
  GATEWAY_DEPLOY="$GATEWAY_DEPLOY" \
  LOADGEN_IMG="${LOADGEN_IMG:-}" \
  LOADGEN_CPU="${LOADGEN_CPU:-}" \
  LOADGEN_MEM="${LOADGEN_MEM:-}" \
  TOP_DELAY_SECS="$TOP_DELAY_SECS" \
  GATEWAY_IMAGE="$gateway_image" \
  GATEWAY_ENV="$gateway_env" \
  GIT_REV="$git_rev" \
  GIT_BRANCH="$git_branch" \
  GIT_DIRTY_COUNT="$git_dirty_count" \
  SUMMARY_FILE="$summary_file" \
  VERDICT_FILE="$verdict_file" \
  CPU_BEFORE_FILE="$cpu_before_file" \
  CPU_AFTER_FILE="$cpu_after_file" \
  CPU_DELTA_FILE="$cpu_delta_file" \
  TOP_FILE="$top_file" \
  POD_FILE="$pod_file" \
  python3 - <<'PY' > "$metadata_file"
import json
import os

fields = [
    "PHASE",
    "ROOT",
    "RUN_DIR",
    "EXPERIMENT_ID",
    "STAMP",
    "LABEL",
    "PREFIX",
    "SESS",
    "WARMUP",
    "MEASURE",
    "RAMP",
    "SPREAD",
    "NS",
    "CTX",
    "SVC",
    "PORT",
    "GATEWAY_DEPLOY",
    "LOADGEN_IMG",
    "LOADGEN_CPU",
    "LOADGEN_MEM",
    "TOP_DELAY_SECS",
    "GATEWAY_IMAGE",
    "GATEWAY_ENV",
    "GIT_REV",
    "GIT_BRANCH",
    "GIT_DIRTY_COUNT",
    "SUMMARY_FILE",
    "VERDICT_FILE",
    "CPU_BEFORE_FILE",
    "CPU_AFTER_FILE",
    "CPU_DELTA_FILE",
    "TOP_FILE",
    "POD_FILE",
]
data = {field.lower(): os.environ.get(field, "") for field in fields}
for key in ("sess", "warmup", "measure", "ramp", "spread", "top_delay_secs", "git_dirty_count"):
    try:
        data[key] = int(data[key])
    except ValueError:
        pass
print(json.dumps(data, indent=2, sort_keys=True))
PY
}

write_cpu_delta() {
  python3 - "$cpu_before_file" "$cpu_after_file" "$cpu_delta_file" <<'PY'
import json
import sys

def parse(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                parts = line.strip().split()
                if len(parts) == 2:
                    try:
                        out[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return out

before = parse(sys.argv[1])
after = parse(sys.argv[2])
delta = {key: after.get(key, 0) - before.get(key, 0) for key in sorted(set(before) | set(after))}
payload = {"before": before, "after": after, "delta": delta}
with open(sys.argv[3], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

append_index() {
  python3 - "$metadata_file" "$summary_file" "$verdict_file" "$cpu_delta_file" "$index_file" <<'PY'
import json
import re
import sys

metadata_path, summary_path, verdict_path, cpu_delta_path, index_path = sys.argv[1:]

def load_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        return {"_error": str(exc), "_path": path}

metadata = load_json(metadata_path)
summary = load_json(summary_path)
cpu = load_json(cpu_delta_path)
try:
    with open(verdict_path, encoding="utf-8") as handle:
        verdict_text = handle.read().strip()
except FileNotFoundError:
    verdict_text = ""

match = re.search(r"\b(PASS|FAIL)\b", verdict_text)
record = {
    "experiment_id": metadata.get("experiment_id"),
    "label": metadata.get("label"),
    "sessions": metadata.get("sess"),
    "verdict": match.group(1) if match else "",
    "verdict_text": verdict_text.splitlines()[-1] if verdict_text else "",
    "summary_file": summary_path,
    "metadata_file": metadata_path,
    "cpu_delta_file": cpu_delta_path,
    "newest_p50_ms": summary.get("newest_frame_to_partial_latency", {}).get("p50_ms"),
    "newest_p95_ms": summary.get("newest_frame_to_partial_latency", {}).get("p95_ms"),
    "oldest_p50_ms": summary.get("oldest_frame_to_partial_latency", {}).get("p50_ms"),
    "oldest_p95_ms": summary.get("oldest_frame_to_partial_latency", {}).get("p95_ms"),
    "flush_p95_ms": summary.get("flush_lateness", {}).get("p95_ms"),
    "partials": summary.get("partials"),
    "protocol_errors": summary.get("protocol_errors"),
    "inference_errors": summary.get("inference_errors"),
    "timeouts": summary.get("timeouts"),
    "cpu_delta": cpu.get("delta", {}),
    "gateway_image": metadata.get("gateway_image"),
    "git_rev": metadata.get("git_rev"),
    "git_branch": metadata.get("git_branch"),
    "git_dirty_count": metadata.get("git_dirty_count"),
}
with open(index_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True))
    handle.write("\n")
PY
}

echo "writing experiment artifacts to $RUN_DIR" >&2
echo "running ${PREFIX}: sessions=${SESS} warmup=${WARMUP} measure=${MEASURE} ramp=${RAMP} spread=${SPREAD}" >&2

git -C "$ROOT" status --short > "$git_status_file" 2>&1 || true
git -C "$ROOT" diff --stat > "$git_diffstat_file" 2>&1 || true
kubectl_ns get deploy "$GATEWAY_DEPLOY" -o yaml > "$deploy_file" 2>&1 || true
kubectl_ns get svc "$SVC" -o yaml > "$svc_file" 2>&1 || true
write_metadata "before"
capture_cpu_stat > "$cpu_before_file" || true

(
  sleep "$TOP_DELAY_SECS"
  {
    echo "# kubectl top pod"
    kubectl_ns top pod 2>&1 || true
    echo
    echo "# benchmark pods"
    kubectl_ns get pod -o wide 2>&1 || true
  } > "$top_file"
) &
top_pid=$!

set +e
RESULTS_DIR="$RUN_DIR" \
SVC="$SVC" \
PORT="$PORT" \
LABEL="$LABEL" \
NS="$NS" \
CTX="$CTX" \
WARMUP="$WARMUP" \
MEASURE="$MEASURE" \
RAMP="$RAMP" \
SPREAD="$SPREAD" \
"$ROOT/scripts/bench/run_point.sh" "$SESS" "$WARMUP" "$MEASURE" "$RAMP" "$SPREAD" \
  | tee "$verdict_file"
run_status=${PIPESTATUS[0]}
set -e

wait "$top_pid" || true
kubectl_ns get pod -o wide > "$pod_file" 2>&1 || true
capture_cpu_stat > "$cpu_after_file" || true
write_cpu_delta
write_metadata "after"
append_index

echo "summary: $summary_file" >&2
echo "metadata: $metadata_file" >&2
echo "cpu delta: $cpu_delta_file" >&2

exit "$run_status"
