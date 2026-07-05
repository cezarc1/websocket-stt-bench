#!/usr/bin/env bash
# Run one fixed k3s experiment point against the no-Async OxCaml epoll gateway.
#
# This only selects the epoll gateway service/deployment. It delegates to
# oxcaml_onechange.sh, preserving the same run_point.sh timing, SLO gates,
# loadgen resources, artifact capture, and one-change experiment discipline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export SVC="${SVC:-stt-ocaml-oxcaml-epoll-gateway}"
export PORT="${PORT:-9200}"
export GATEWAY_DEPLOY="${GATEWAY_DEPLOY:-stt-ocaml-oxcaml-epoll-gateway}"
export EXPERIMENT_ID="${EXPERIMENT_ID:-oxcaml-epoll}"
export LABEL="${LABEL:-${EXPERIMENT_ID}}"

exec "$ROOT/scripts/bench/oxcaml_onechange.sh" "${1:-${SESS:-2200}}"
