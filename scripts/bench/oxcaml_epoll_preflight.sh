#!/usr/bin/env bash
# Local-only preflight for the no-Async OxCaml epoll benchmark path.
#
# This script deliberately does not push images, dispatch workflows, apply
# manifests, scale deployments, or create loadgen Jobs. It validates local
# wiring and prints the exact approval-gated commands for the real k3s run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="${NS:-stt-bench}"
CTX="${CTX:-}"
IMAGE=""
SESS="${SESS:-2200}"

usage() {
  cat >&2 <<'USAGE'
usage: oxcaml_epoll_preflight.sh --image IMAGE [--sessions N] [--namespace NS] [--context CTX]

Validates local epoll benchmark wiring without mutating GitHub, Docker
registries, or Kubernetes. Prints the approval-gated commands to run next.
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

branch="$(git -C "$ROOT" branch --show-current)"

bash "$ROOT/scripts/bench/test_oxcaml_epoll_source_guards.sh"
bash "$ROOT/scripts/bench/test_oxcaml_epoll_deploy.sh"
helm lint "$ROOT/charts/stt-bench" >/dev/null
rendered_chart="$(helm template stt-bench "$ROOT/charts/stt-bench" \
  --set images.repository=cezarc1/websocket-stt-bench \
  --set images.tag=epoll-preflight \
  --set gateways.ocamlOxcamlEpoll.enabled=true)"
grep -Fq 'image: ghcr.io/cezarc1/websocket-stt-bench/ocaml-oxcaml-epoll:epoll-preflight' \
  <<<"$rendered_chart"

deploy_args=(--print-manifest --namespace "$NS" --image "$IMAGE")
if [ -n "$CTX" ]; then
  deploy_args+=(--context "$CTX")
fi
manifest="$("$ROOT/scripts/bench/oxcaml_epoll_deploy.sh" "${deploy_args[@]}")"
kubectl apply --dry-run=client -f - <<<"$manifest" >/dev/null

cat <<OUT
epoll preflight ok

Approval-gated next commands:
  gh workflow run images.yml --ref $branch -f image=ocaml-oxcaml-epoll
  scripts/bench/oxcaml_epoll_k3s_point.sh${CTX:+ --context $CTX} --namespace $NS --image $IMAGE --sessions $SESS
OUT
