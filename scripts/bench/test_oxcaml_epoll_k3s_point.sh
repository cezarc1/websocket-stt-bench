#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/bench/oxcaml_epoll_k3s_point.sh"
IMAGE="ghcr.io/example/ocaml-oxcaml-epoll:test"
TMPDIR="$(mktemp -d)"
LOG="$TMPDIR/calls.log"
trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"$OXCAML_EPOLL_TEST_LOG"
if [ "$#" -ge 7 ] \
  && [ "$1" = "--context" ] \
  && [ "$3" = "-n" ] \
  && [ "$5" = "get" ] \
  && [ "$6" = "pod" ]; then
  case "$*" in
    *"jsonpath={.items[0].metadata.name}"*) printf 'stt-ocaml-oxcaml-epoll-gateway-test-pod' ;;
    *"jsonpath={.items[0].spec.nodeName}"*) printf 'cezar-4090' ;;
    *"jsonpath={.items[0].spec.containers[0].image}"*) printf '%s' "$OXCAML_EPOLL_EXPECTED_IMAGE" ;;
  esac
fi
if [ "$#" -ge 7 ] \
  && [ "$1" = "--context" ] \
  && [ "$3" = "-n" ] \
  && [ "$5" = "get" ] \
  && [ "$6" = "deploy" ] \
  && [ "$7" = "stt-ocaml-oxcaml-epoll-gateway" ]; then
  case "$*" in
    *"jsonpath={.spec.template.spec.containers[0].image}"*) printf '%s' "$OXCAML_EPOLL_EXPECTED_IMAGE" ;;
    *"jsonpath={.status.replicas}"*) printf '1' ;;
    *"jsonpath={.status.readyReplicas}"*) printf '1' ;;
  esac
fi
if [ "$#" -ge 6 ] \
  && [ "$1" = "--context" ] \
  && [ "$3" = "get" ] \
  && [ "$4" = "node" ] \
  && [ "$5" = "cezar-4090" ]; then
  case "$*" in
    *"jsonpath={.metadata.labels.kubernetes\\.io/arch}"*) printf 'amd64' ;;
  esac
fi
exit 0
STUB

cat >"$TMPDIR/oxcaml_epoll_deploy.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'deploy %s\n' "$*" >>"$OXCAML_EPOLL_TEST_LOG"
exit 0
STUB

cat >"$TMPDIR/oxcaml_epoll_onechange.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'onechange CTX=%s NS=%s LOADGEN_IMG=%s args=%s\n' \
  "${CTX:-}" "${NS:-}" "${LOADGEN_IMG:-}" "$*" >>"$OXCAML_EPOLL_TEST_LOG"
exit "${OXCAML_EPOLL_ONECHANGE_RC:-0}"
STUB

chmod +x "$TMPDIR/kubectl" "$TMPDIR/oxcaml_epoll_deploy.sh" "$TMPDIR/oxcaml_epoll_onechange.sh"

run_script() {
  PATH="$TMPDIR:$PATH" \
  OXCAML_EPOLL_TEST_LOG="$LOG" \
  OXCAML_EPOLL_SCRIPT_DIR="$TMPDIR" \
  OXCAML_EPOLL_EXPECTED_IMAGE="$IMAGE" \
  "$SCRIPT" \
    --image "$IMAGE" \
    --context dry-run-context \
    --namespace stt-bench \
    --sessions 2200 \
    --experiment-id epoll-test \
    --label epoll-test-label \
    >/dev/null 2>&1
}

assert_log_contains() {
  local needle="$1"
  if ! grep -Fq -- "$needle" "$LOG"; then
    echo "expected k3s point log to contain: $needle" >&2
    echo "--- log ---" >&2
    cat "$LOG" >&2
    exit 1
  fi
}

assert_log_empty() {
  if [ -s "$LOG" ]; then
    echo "expected k3s point log to be empty" >&2
    echo "--- log ---" >&2
    cat "$LOG" >&2
    exit 1
  fi
}

set +e
PATH="$TMPDIR:$PATH" \
OXCAML_EPOLL_TEST_LOG="$LOG" \
OXCAML_EPOLL_SCRIPT_DIR="$TMPDIR" \
OXCAML_EPOLL_EXPECTED_IMAGE="$IMAGE" \
GATEWAY_REPLICAS=2 \
"$SCRIPT" \
  --image "$IMAGE" \
  --context dry-run-context \
  --namespace stt-bench \
  --sessions 2200 \
  --experiment-id epoll-test \
  --label epoll-test-label \
  >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  echo "expected wrapper to reject non-1 gateway replica count with status 2, got $rc" >&2
  echo "--- log ---" >&2
  cat "$LOG" >&2
  exit 1
fi
assert_log_empty

: >"$LOG"
run_script
assert_log_contains "kubectl --context dry-run-context -n stt-bench scale deploy/stt-inference-server --replicas=4"
assert_log_contains "deploy --context dry-run-context --namespace stt-bench --image $IMAGE --replicas 1 --apply"
assert_log_contains "kubectl --context dry-run-context -n stt-bench rollout status deploy/stt-inference-server --timeout=240s"
assert_log_contains "kubectl --context dry-run-context -n stt-bench rollout status deploy/stt-ocaml-oxcaml-epoll-gateway --timeout=240s"
assert_log_contains "kubectl --context dry-run-context -n stt-bench get deploy stt-ocaml-oxcaml-epoll-gateway -o jsonpath={.status.replicas}"
assert_log_contains "kubectl --context dry-run-context -n stt-bench get deploy stt-ocaml-oxcaml-epoll-gateway -o jsonpath={.status.readyReplicas}"
assert_log_contains "kubectl --context dry-run-context -n stt-bench get deploy stt-ocaml-oxcaml-epoll-gateway -o jsonpath={.spec.template.spec.containers[0].image}"
assert_log_contains "kubectl --context dry-run-context -n stt-bench get pod -l app=stt-ocaml-oxcaml-epoll-gateway -o jsonpath={.items[0].spec.containers[0].image}"
assert_log_contains "kubectl --context dry-run-context -n stt-bench get pod -l app=stt-ocaml-oxcaml-epoll-gateway -o jsonpath={.items[0].spec.nodeName}"
assert_log_contains "kubectl --context dry-run-context get node cezar-4090 -o jsonpath={.metadata.labels.kubernetes\\.io/arch}"
assert_log_contains "onechange CTX=dry-run-context NS=stt-bench LOADGEN_IMG=ghcr.io/cezarc1/websocket-stt-bench/loadgen:main args=2200"
assert_log_contains "deploy --context dry-run-context --namespace stt-bench --image $IMAGE --replicas 0 --apply"
assert_log_contains "kubectl --context dry-run-context -n stt-bench scale deploy/stt-inference-server --replicas=0"

: >"$LOG"
set +e
PATH="$TMPDIR:$PATH" \
OXCAML_EPOLL_TEST_LOG="$LOG" \
OXCAML_EPOLL_SCRIPT_DIR="$TMPDIR" \
OXCAML_EPOLL_EXPECTED_IMAGE="$IMAGE" \
OXCAML_EPOLL_ONECHANGE_RC=37 \
"$SCRIPT" \
  --image "$IMAGE" \
  --context dry-run-context \
  --namespace stt-bench \
  --sessions 2200 \
  --experiment-id epoll-test \
  --label epoll-test-label \
  >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 37 ]; then
  echo "expected wrapper to return failed benchmark status 37, got $rc" >&2
  echo "--- log ---" >&2
  cat "$LOG" >&2
  exit 1
fi
assert_log_contains "onechange CTX=dry-run-context NS=stt-bench LOADGEN_IMG=ghcr.io/cezarc1/websocket-stt-bench/loadgen:main args=2200"
assert_log_contains "deploy --context dry-run-context --namespace stt-bench --image $IMAGE --replicas 0 --apply"
assert_log_contains "kubectl --context dry-run-context -n stt-bench scale deploy/stt-inference-server --replicas=0"
