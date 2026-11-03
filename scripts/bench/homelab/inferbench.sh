#!/usr/bin/env bash
# Open-loop capacity check of the in-cluster inference Service (run before a
# sweep: every gateway ceiling must sit well below the rate where this
# saturates). 50-frame payloads, i.e. one gateway flush per request.
#   scripts/bench/homelab/inferbench.sh <rps> [loadgen-image-tag]
set -euo pipefail
RPS=$1; TAG=${2:-colocated-rerun}; JOB=stt-inferbench-probe-$RPS
K=(kubectl --context cezar-4090-cluster -n stt-bench --request-timeout=30s)
"${K[@]}" delete job "$JOB" --ignore-not-found >/dev/null 2>&1
cat <<YAML | "${K[@]}" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: $JOB }
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      nodeSelector: { kubernetes.io/hostname: cezar-4090 }
      imagePullSecrets: [ { name: ghcr-pull-secret } ]
      containers:
        - name: inferbench
          image: ghcr.io/cezarc1/websocket-stt-bench/loadgen:$TAG
          command: ["stt-inferbench"]
          args: ["--url","http://stt-inference-server.stt-bench.svc.cluster.local:9000/infer","--rps","$RPS","--concurrency","4096","--clients","16","--duration-secs","40","--payload-frames","50","--timeout-ms","2000"]
          resources: { requests: { cpu: "4", memory: 2Gi }, limits: { cpu: "4", memory: 2Gi } }
YAML
"${K[@]}" wait --for=condition=complete --timeout=240s job/"$JOB" >/dev/null 2>&1 || true
"${K[@]}" logs job/"$JOB" 2>/dev/null | tail -c 3000
"${K[@]}" delete job "$JOB" --ignore-not-found >/dev/null 2>&1
