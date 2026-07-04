#!/usr/bin/env bash
# Render or apply only the experimental no-Async OxCaml epoll gateway objects.
#
# This intentionally avoids a broad Helm upgrade while the release may contain
# unrelated state. It creates/updates just the epoll Deployment and Service that
# scripts/bench/oxcaml_epoll_onechange.sh targets.
set -euo pipefail

NS="${NS:-stt-bench}"
CTX="${CTX:-}"
IMAGE=""
REPLICAS="${REPLICAS:-0}"
MODE="print"

usage() {
  cat >&2 <<'USAGE'
usage: oxcaml_epoll_deploy.sh --image IMAGE [--replicas N] [--namespace NS] [--context CTX] [--print-manifest|--apply]

Default mode is --print-manifest. --apply mutates the selected Kubernetes
namespace and should be used only after the experiment image has been pushed.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      IMAGE="${2:?--image requires a value}"
      shift 2
      ;;
    --replicas)
      REPLICAS="${2:?--replicas requires a value}"
      shift 2
      ;;
    --namespace|-n)
      NS="${2:?--namespace requires a value}"
      shift 2
      ;;
    --context)
      CTX="${2:?--context requires a value}"
      shift 2
      ;;
    --print-manifest)
      MODE="print"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$IMAGE" ]; then
  usage
  echo "--image is required" >&2
  exit 2
fi

KCTX=()
[ -n "$CTX" ] && KCTX=(--context "$CTX")

manifest() {
  cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stt-ocaml-oxcaml-epoll-gateway
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: stt-bench
    app.kubernetes.io/instance: stt-bench
    app.kubernetes.io/managed-by: manual
    app: stt-ocaml-oxcaml-epoll-gateway
    component: gateway
    gateway: ocamlOxcamlEpoll
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: stt-ocaml-oxcaml-epoll-gateway
  template:
    metadata:
      labels:
        app: stt-ocaml-oxcaml-epoll-gateway
        component: gateway
        gateway: ocamlOxcamlEpoll
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
      imagePullSecrets:
        - name: ghcr-pull-secret
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: gateway
          image: ${IMAGE}
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 9200
          env:
            - name: PORT
              value: "9200"
            - name: CPU_PASSES
              value: "4"
            - name: MODEL_DELAY_MS
              value: "75"
            - name: FLUSH_INTERVAL_MS
              value: "1000"
            - name: FLUSH_PHASE_JITTER_MS
              value: "1000"
            - name: INFERENCE_URL
              value: "http://stt-inference-server.stt-bench.svc.cluster.local:9000"
            - name: WORKER_THREADS
              value: "1"
            - name: INFERENCE_HTTP_CLIENTS
              value: "512"
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 12
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
            limits:
              cpu: "1"
              memory: 2Gi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: stt-ocaml-oxcaml-epoll-gateway
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: stt-bench
    app.kubernetes.io/instance: stt-bench
    app.kubernetes.io/managed-by: manual
    app: stt-ocaml-oxcaml-epoll-gateway
    component: gateway
    gateway: ocamlOxcamlEpoll
spec:
  type: ClusterIP
  selector:
    app: stt-ocaml-oxcaml-epoll-gateway
  ports:
    - name: http
      port: 9200
      targetPort: http
YAML
}

case "$MODE" in
  print)
    manifest
    ;;
  apply)
    manifest | kubectl "${KCTX[@]}" apply -f -
    ;;
  *)
    echo "invalid mode: $MODE" >&2
    exit 2
    ;;
esac
