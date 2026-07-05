#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/bench/oxcaml_epoll_deploy.sh"
RUN_POINT="$ROOT/scripts/bench/run_point.sh"
IMAGE="ghcr.io/example/ocaml-oxcaml-epoll:test"

manifest="$("$SCRIPT" --print-manifest --image "$IMAGE")"
override_manifest="$(INFERENCE_HTTP_CLIENTS=1024 "$SCRIPT" --print-manifest --image "$IMAGE")"

assert_contains() {
  local needle="$1"
  if ! grep -Fq "$needle" <<<"$manifest"; then
    echo "expected manifest to contain: $needle" >&2
    exit 1
  fi
}

assert_contains "name: stt-ocaml-oxcaml-epoll-gateway"
assert_contains "image: $IMAGE"
assert_contains "containerPort: 9200"
assert_contains "port: 9200"
assert_contains "nodeSelector:"
assert_contains "kubernetes.io/arch: amd64"
assert_contains "name: INFERENCE_HTTP_CLIENTS"
assert_contains 'value: "512"'
assert_contains 'cpu: "1"'
assert_contains "memory: 2Gi"

if ! grep -Fq 'value: "1024"' <<<"$override_manifest"; then
  echo "expected INFERENCE_HTTP_CLIENTS env override to reach manifest" >&2
  exit 1
fi

if ! grep -Fq 'LOADGEN_IMG="${LOADGEN_IMG:-ghcr.io/cezarc1/websocket-stt-bench/loadgen:main}"' "$RUN_POINT"; then
  echo "run_point.sh default LOADGEN_IMG must be the comparable :main image" >&2
  exit 1
fi
