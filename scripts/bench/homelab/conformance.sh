#!/usr/bin/env bash
# In-cluster black-box conformance for every 1-vCPU gateway at once.
#   scripts/bench/homelab/conformance.sh [image-tag] [placement-values]
# ONLY="chartKey1 chartKey2" limits the run. Scales the gateways back to 0.
set -uo pipefail
TAG=${1:-colocated-rerun}
PLACEMENT=${2:-values-colocated.yaml}
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
K=(kubectl --context cezar-4090-cluster -n stt-bench --request-timeout=30s)
H=(helm --kube-context cezar-4090-cluster -n stt-bench)
VALS=(-f "$REPO/charts/stt-bench/$PLACEMENT" -f "$REPO/scripts/bench/homelab/values-1vcpu.yaml")
GWS="rust:stt-rust-axum-gateway:3000
rustSync:stt-rust-sync-gateway:10000
cpp23UWebsockets:stt-cpp23-uwebsockets-gateway:1500
ocamlOxcamlEpoll:stt-ocaml-oxcaml-epoll-gateway:9200
javaHelidonNima:stt-java-helidon-nima-gateway:5000
typescriptBun:stt-typescript-bun-gateway:7000
goNethttp:stt-go-nethttp-gateway:6000
ocamlOxcaml:stt-ocaml-oxcaml-gateway:9000
ocamlWebsocketAsync:stt-ocaml-websocket-async-gateway:9100
scalaPekko:stt-scala-pekko-gateway:2500
elixir:stt-elixir-phoenix-gateway:4000
pythonGil:stt-python-fastapi-gil-gateway:8000
pythonFt:stt-python-fastapi-ft-gateway:8000"
if [ -n "${ONLY:-}" ]; then GWS=$(printf "%s\n" "$GWS" | grep -E "^($(echo "$ONLY" | tr ' ' '|')):"); fi
SETS=(); ARGS=()
while IFS=: read -r key svc port; do
  SETS+=(--set "gateways.${key}.replicas=1")
  ARGS+=("\"--service\",\"${svc}=ws://${svc}.stt-bench.svc.cluster.local:${port}/ws/stt\"")
done <<< "$GWS"
echo "[$(date +%T)] scaling gateways to 1 (tag $TAG, $PLACEMENT)"
"${H[@]}" upgrade --install stt-bench "$REPO/charts/stt-bench" "${VALS[@]}" --set images.tag="$TAG" "${SETS[@]}" --wait --timeout 10m >/dev/null \
  || { echo "helm scale-up failed"; "${K[@]}" get pods -o wide; }
"${K[@]}" get pods -o wide --no-headers | awk '{print $1, $3, $4, $7}'
JOB=stt-conformance-all
"${K[@]}" delete job $JOB --ignore-not-found >/dev/null 2>&1
cat <<YAML | "${K[@]}" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: $JOB }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      nodeSelector: { kubernetes.io/hostname: cezar-4090 }
      imagePullSecrets: [ { name: ghcr-pull-secret } ]
      containers:
        - name: conformance
          image: ghcr.io/cezarc1/websocket-stt-bench/loadgen:$TAG
          imagePullPolicy: Always
          command: ["stt-conformance"]
          args: [$(IFS=,; echo "${ARGS[*]}")]
          resources: { requests: { cpu: "2", memory: 1Gi }, limits: { cpu: "2", memory: 1Gi } }
YAML
for _ in $(seq 1 240); do
  s=$("${K[@]}" get job $JOB -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)
  [ -n "$s" ] && break; sleep 5
done
echo "[$(date +%T)] conformance output:"
"${K[@]}" logs job/$JOB
"${K[@]}" get pods --no-headers | awk '$4!="0"{print "RESTARTED:", $1, $4}'
echo "[$(date +%T)] scaling gateways back to 0"
"${H[@]}" upgrade --install stt-bench "$REPO/charts/stt-bench" "${VALS[@]}" --set images.tag="$TAG" --wait --timeout 10m >/dev/null
