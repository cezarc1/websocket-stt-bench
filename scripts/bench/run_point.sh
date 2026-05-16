#!/usr/bin/env bash
# Run ONE benchmark point against an in-cluster gateway and evaluate it
# against the websocket-stt-bench SLO gates.
#
#   SVC=<k8s-service> PORT=<port> LABEL=<prefix> \
#     scripts/bench/run_point.sh <sessions> [warmup] [measure] [ramp] [spread]
#
# Gateway-agnostic: it targets a Kubernetes Service by name, so it measures
# whatever pod(s) back that Service (1 replica = single-pod; N replicas =
# fan-out). This is the same harness for every runtime — that is what makes
# the numbers comparable.
#
# ── COMPARABILITY CONTRACT (do NOT change per-runtime) ───────────────────
#   warmup 10s / measured 45s / ramp 30s / session-start spread 1000ms,
#   1 repeat, no --max-error-rate (loadgen must always emit summary JSON so
#   the driver evaluates the SLO itself and can bracket a failing point).
#   SLO gates live in eval_slo.py and are identical for all runtimes.
# A point is only a real result if it is reproducible: re-run a pass to
# "confirm"; a point that is 1 pass / 1 fail is "borderline", not headline.
# ─────────────────────────────────────────────────────────────────────────
#
# Required env:
#   SVC      k8s Service name           e.g. stt-go-nethttp-gateway
#   PORT     Service port               e.g. 6000
#   LABEL    results filename prefix     e.g. go-nethttp-1vcpu-2gib
# Optional env:
#   NS        namespace      (default: stt-bench)
#   CTX       kube-context   (default: current context; pass it explicitly
#             if your context flips, e.g. Docker Desktop hijacking kube)
#   WS_PATH   ws path        (default: /ws/stt)
#   LOADGEN_IMG  loadgen image (default below; any tag works, the loadgen
#                contract is stable across branches)
#   RESULTS_DIR  local dir for the captured summary (default /tmp/bench/results;
#                results are gitignored artifacts, not tracked)
#   LOADGEN_CPU / LOADGEN_MEM  loadgen Job resources (default 4 / 4Gi)
set -euo pipefail

SESS="${1:?usage: SVC=.. PORT=.. LABEL=.. run_point.sh <sessions> [warmup measure ramp spread]}"
WARMUP="${2:-10}"
MEASURE="${3:-45}"
RAMP="${4:-30}"
SPREAD="${5:-1000}"

SVC="${SVC:?set SVC to the gateway k8s Service name}"
PORT="${PORT:?set PORT to the gateway Service port}"
LABEL="${LABEL:?set LABEL to the results filename prefix}"
NS="${NS:-stt-bench}"
WS_PATH="${WS_PATH:-/ws/stt}"
LOADGEN_IMG="${LOADGEN_IMG:-ghcr.io/cezarc1/websocket-stt-bench/loadgen:feature-scala-pekko-gateway}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/bench/results}"
LOADGEN_CPU="${LOADGEN_CPU:-4}"
LOADGEN_MEM="${LOADGEN_MEM:-4Gi}"

# CTX is optional; if set we pass --context everywhere (kube context can flip
# when Docker Desktop touches kube — pass it explicitly to be safe).
KCTX=()
[ -n "${CTX:-}" ] && KCTX=(--context "$CTX")

GW_URL="ws://${SVC}.${NS}.svc.cluster.local:${PORT}${WS_PATH}"
PREFIX="${LABEL}-${SESS}"
JOB="stt-loadgen-${LABEL}-${SESS}"

kubectl "${KCTX[@]}" -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true

cat <<YAML | kubectl "${KCTX[@]}" -n "$NS" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  labels: { app: stt-benchmark, component: loadgen }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app: stt-benchmark, component: loadgen }
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: ghcr-pull-secret
      containers:
        - name: loadgen
          image: ${LOADGEN_IMG}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh","-lc"]
          args:
            - |
              set -eu
              mkdir -p /results
              sleep 5
              stt-loadgen \
                --url ${GW_URL} \
                --service-name ${PREFIX} \
                --sessions ${SESS} \
                --warmup-secs ${WARMUP} \
                --measure-secs ${MEASURE} \
                --ramp-up-secs ${RAMP} \
                --session-start-spread-ms ${SPREAD} \
                --repeat 1 \
                --samples-out /results/${PREFIX}.samples.csv \
                > /results/${PREFIX}.summary.json 2>/results/${PREFIX}.warn.log || true
              cat /results/${PREFIX}.summary.json
          resources:
            requests: { cpu: "${LOADGEN_CPU}", memory: ${LOADGEN_MEM} }
            limits: { cpu: "${LOADGEN_CPU}", memory: ${LOADGEN_MEM} }
YAML

BUDGET=$(( 5 + RAMP + WARMUP + MEASURE + 120 ))
DEADLINE=$(( $(date +%s) + BUDGET ))
while :; do
  PHASE=$(kubectl "${KCTX[@]}" -n "$NS" get pod -l "job-name=${JOB}" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  case "$PHASE" in
    Succeeded|Failed) break ;;
  esac
  [ "$(date +%s)" -ge "$DEADLINE" ] && break
  sleep 5
done

POD=$(kubectl "${KCTX[@]}" -n "$NS" get pod -l "job-name=${JOB}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
LOG=$(kubectl "${KCTX[@]}" -n "$NS" logs "${POD}" 2>/dev/null || true)
JSON=$(printf '%s\n' "$LOG" | awk '/^\{/{f=1} f' | head -c 200000)
mkdir -p "$RESULTS_DIR"
printf '%s' "$JSON" > "${RESULTS_DIR}/${PREFIX}.summary.json"

printf '%s' "$JSON" | python3 "$(dirname "$0")/eval_slo.py" "$SESS"

kubectl "${KCTX[@]}" -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1 || true
