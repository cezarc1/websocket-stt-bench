#!/usr/bin/env bash
# Approval-gated k3s lifecycle wrapper for one OxCaml epoll benchmark point.
#
# This script mutates the selected cluster when run: it scales inference,
# applies the epoll Deployment/Service, runs the official one-change wrapper,
# then scales inference and the epoll gateway back to zero by default.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${OXCAML_EPOLL_SCRIPT_DIR:-$ROOT/scripts/bench}"

NS="${NS:-stt-bench}"
CTX="${CTX:-}"
IMAGE=""
SESS="${SESS:-2200}"
INFERENCE_REPLICAS="${INFERENCE_REPLICAS:-4}"
GATEWAY_REPLICAS="${GATEWAY_REPLICAS:-1}"
EXPERIMENT_ID="${EXPERIMENT_ID:-oxcaml-epoll}"
LABEL="${LABEL:-$EXPERIMENT_ID}"
LOADGEN_IMG="${LOADGEN_IMG:-ghcr.io/cezarc1/websocket-stt-bench/loadgen:main}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-240s}"
CLEANUP=1

usage() {
  cat >&2 <<'USAGE'
usage: oxcaml_epoll_k3s_point.sh --image IMAGE [--sessions N] [--namespace NS] [--context CTX]
                                  [--inference-replicas N] [--experiment-id ID]
                                  [--label LABEL] [--no-cleanup]

Mutates the selected Kubernetes cluster. Use only after image publication and
explicit approval. It preserves the official benchmark runner and SLO gates by
delegating the actual load point to scripts/bench/oxcaml_epoll_onechange.sh.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      IMAGE="${2:?--image requires a value}"
      shift 2
      ;;
    --sessions)
      SESS="${2:?--sessions requires a value}"
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
    --inference-replicas)
      INFERENCE_REPLICAS="${2:?--inference-replicas requires a value}"
      shift 2
      ;;
    --experiment-id)
      EXPERIMENT_ID="${2:?--experiment-id requires a value}"
      shift 2
      ;;
    --label)
      LABEL="${2:?--label requires a value}"
      shift 2
      ;;
    --no-cleanup)
      CLEANUP=0
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

if [[ "$IMAGE" != *"/ocaml-oxcaml-epoll:"* ]]; then
  echo "--image must point at an ocaml-oxcaml-epoll tag: $IMAGE" >&2
  exit 2
fi

if [ "$GATEWAY_REPLICAS" != "1" ]; then
  echo "GATEWAY_REPLICAS must remain 1 for the 1-vCPU epoll benchmark: $GATEWAY_REPLICAS" >&2
  exit 2
fi

KCTX=()
[ -n "$CTX" ] && KCTX=(--context "$CTX")

kubectl_ns() {
  kubectl "${KCTX[@]}" -n "$NS" "$@"
}

kubectl_cluster() {
  kubectl "${KCTX[@]}" "$@"
}

deploy_epoll() {
  local replicas="$1"
  deploy_args=(--namespace "$NS" --image "$IMAGE" --replicas "$replicas" --apply)
  if [ -n "$CTX" ]; then
    deploy_args=(--context "$CTX" "${deploy_args[@]}")
  fi
  "$SCRIPT_DIR/oxcaml_epoll_deploy.sh" "${deploy_args[@]}"
}

verify_gateway_single_replica() {
  local replicas ready
  replicas="$(kubectl_ns get deploy stt-ocaml-oxcaml-epoll-gateway \
    -o 'jsonpath={.status.replicas}')"
  ready="$(kubectl_ns get deploy stt-ocaml-oxcaml-epoll-gateway \
    -o 'jsonpath={.status.readyReplicas}')"
  if [ "${replicas:-0}" != "1" ] || [ "${ready:-0}" != "1" ]; then
    echo "epoll gateway replica state is replicas=${replicas:-0} ready=${ready:-0}, expected 1/1" >&2
    exit 1
  fi
  echo "epoll gateway replica state verified: replicas=1 ready=1" >&2
}

verify_gateway_image() {
  local deploy_image pod_image
  deploy_image="$(kubectl_ns get deploy stt-ocaml-oxcaml-epoll-gateway \
    -o 'jsonpath={.spec.template.spec.containers[0].image}')"
  if [ "$deploy_image" != "$IMAGE" ]; then
    echo "epoll deployment image is $deploy_image, expected $IMAGE" >&2
    exit 1
  fi
  pod_image="$(kubectl_ns get pod -l app=stt-ocaml-oxcaml-epoll-gateway \
    -o 'jsonpath={.items[0].spec.containers[0].image}')"
  if [ "$pod_image" != "$IMAGE" ]; then
    echo "epoll pod image is $pod_image, expected $IMAGE" >&2
    exit 1
  fi
  echo "epoll gateway image verified: $IMAGE" >&2
}

verify_gateway_node_arch() {
  local node arch
  node="$(kubectl_ns get pod -l app=stt-ocaml-oxcaml-epoll-gateway \
    -o 'jsonpath={.items[0].spec.nodeName}')"
  if [ -z "$node" ]; then
    echo "could not resolve scheduled node for stt-ocaml-oxcaml-epoll-gateway" >&2
    exit 1
  fi
  arch="$(kubectl_cluster get node "$node" \
    -o 'jsonpath={.metadata.labels.kubernetes\.io/arch}')"
  if [ "$arch" != "amd64" ]; then
    echo "epoll gateway scheduled on $node with arch=$arch, expected amd64" >&2
    exit 1
  fi
  echo "epoll gateway scheduled on $node ($arch)" >&2
}

cleanup() {
  if [ "$CLEANUP" -eq 1 ]; then
    deploy_epoll 0 || true
    kubectl_ns scale deploy/stt-inference-server --replicas=0 || true
  fi
}
trap cleanup EXIT

echo "scaling inference to ${INFERENCE_REPLICAS} and epoll gateway to ${GATEWAY_REPLICAS}" >&2
kubectl_ns scale deploy/stt-inference-server --replicas="$INFERENCE_REPLICAS"
deploy_epoll "$GATEWAY_REPLICAS"

kubectl_ns rollout status deploy/stt-inference-server --timeout="$ROLLOUT_TIMEOUT"
kubectl_ns rollout status deploy/stt-ocaml-oxcaml-epoll-gateway --timeout="$ROLLOUT_TIMEOUT"
verify_gateway_single_replica
verify_gateway_image
verify_gateway_node_arch

CTX="$CTX" \
NS="$NS" \
LOADGEN_IMG="$LOADGEN_IMG" \
EXPERIMENT_ID="$EXPERIMENT_ID" \
LABEL="$LABEL" \
"$SCRIPT_DIR/oxcaml_epoll_onechange.sh" "$SESS"
