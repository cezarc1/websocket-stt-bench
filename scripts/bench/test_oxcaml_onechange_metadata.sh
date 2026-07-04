#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/bench/oxcaml_onechange.sh"
TMPDIR="$(mktemp -d)"
RUN_DIR="$TMPDIR/results"
LOG="$TMPDIR/kubectl.log"
trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"$OXCAML_ONECHANGE_TEST_LOG"

case "$*" in
  *"apply -f -"*)
    cat >/dev/null
    exit 0
    ;;
  *"delete job"*)
    exit 0
    ;;
  *"get pod -l job-name="*"jsonpath={.items[0].status.phase}"*)
    printf 'Succeeded'
    exit 0
    ;;
  *"get pod -l job-name="*"jsonpath={.items[0].metadata.name}"*)
    printf 'stt-loadgen-test-pod'
    exit 0
    ;;
  *"logs stt-loadgen-test-pod"*)
    cat <<'JSON'
{
  "partials": 1,
  "protocol_errors": 0,
  "inference_errors": 0,
  "timeouts": {"connect": 0, "send": 0, "close": 0, "session": 0},
  "newest_frame_to_partial_latency": {"p50_ms": 100, "p95_ms": 120},
  "oldest_frame_to_partial_latency": {"p50_ms": 1000, "p95_ms": 1100},
  "flush_lateness": {"p95_ms": 2}
}
JSON
    exit 0
    ;;
  *"exec deploy/stt-ocaml-oxcaml-epoll-gateway"*)
    printf 'usage_usec 100\nuser_usec 70\nsystem_usec 30\n'
    exit 0
    ;;
  *"get deploy stt-ocaml-oxcaml-epoll-gateway -o yaml"*)
    printf 'kind: Deployment\nmetadata:\n  name: stt-ocaml-oxcaml-epoll-gateway\n'
    exit 0
    ;;
  *"get svc stt-ocaml-oxcaml-epoll-gateway -o yaml"*)
    printf 'kind: Service\nmetadata:\n  name: stt-ocaml-oxcaml-epoll-gateway\n'
    exit 0
    ;;
  *"get deploy stt-ocaml-oxcaml-epoll-gateway"*"jsonpath={.spec.template.spec.containers[0].image}"*)
    printf 'ghcr.io/example/ocaml-oxcaml-epoll:sha-test'
    exit 0
    ;;
  *"get deploy stt-ocaml-oxcaml-epoll-gateway"*"jsonpath={range .spec.template.spec.containers[0].env[*]}"*)
    printf 'PORT=9200\nINFERENCE_HTTP_CLIENTS=512\n'
    exit 0
    ;;
  *"get pod -l app=stt-ocaml-oxcaml-epoll-gateway"*"jsonpath={.items[0].status.containerStatuses[0].imageID}"*)
    printf 'ghcr.io/example/ocaml-oxcaml-epoll@sha256:abcdef'
    exit 0
    ;;
  *"top pod"*)
    printf 'NAME CPU(cores) MEMORY(bytes)\nstt-ocaml-oxcaml-epoll-gateway 900m 128Mi\n'
    exit 0
    ;;
  *"get pod -o wide"*)
    printf 'NAME READY STATUS RESTARTS AGE IP NODE\nstt-ocaml-oxcaml-epoll-gateway 1/1 Running 0 1m 10.0.0.1 cezar-4090\n'
    exit 0
    ;;
esac

echo "unexpected kubectl invocation: $*" >&2
exit 20
STUB

chmod +x "$TMPDIR/kubectl"

PATH="$TMPDIR:$PATH" \
OXCAML_ONECHANGE_TEST_LOG="$LOG" \
CTX=dry-run-context \
NS=stt-bench \
SVC=stt-ocaml-oxcaml-epoll-gateway \
PORT=9200 \
GATEWAY_DEPLOY=stt-ocaml-oxcaml-epoll-gateway \
EXPERIMENT_ID=oxcaml-onechange-test \
LABEL=oxcaml-onechange-test \
STAMP=20260704T000000Z \
RUN_DIR="$RUN_DIR" \
TOP_DELAY_SECS=0 \
"$SCRIPT" 2200 >/dev/null

metadata="$RUN_DIR/oxcaml-onechange-test-2200.metadata.json"
index="$RUN_DIR/experiments.jsonl"

if [ "$(jq -r '.gateway_image_id' "$metadata")" != "ghcr.io/example/ocaml-oxcaml-epoll@sha256:abcdef" ]; then
  echo "expected metadata to include live gateway image digest" >&2
  cat "$metadata" >&2
  exit 1
fi

if [ "$(jq -r '.gateway_image_id' "$index")" != "ghcr.io/example/ocaml-oxcaml-epoll@sha256:abcdef" ]; then
  echo "expected experiments index to include live gateway image digest" >&2
  cat "$index" >&2
  exit 1
fi
