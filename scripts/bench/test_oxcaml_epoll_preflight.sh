#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/bench/oxcaml_epoll_preflight.sh"
IMAGE="ghcr.io/example/ocaml-oxcaml-epoll:test"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 4 ] \
  && [ "$1" = "apply" ] \
  && [ "$2" = "--dry-run=client" ] \
  && [ "$3" = "-f" ] \
  && [ "$4" = "-" ]; then
  cat >/dev/null
  exit 0
fi
echo "unexpected kubectl invocation: $*" >&2
exit 20
STUB

cat >"$TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "preflight must not execute gh: $*" >&2
exit 21
STUB

cat >"$TMPDIR/docker" <<'STUB'
#!/usr/bin/env bash
echo "preflight must not execute docker: $*" >&2
exit 22
STUB

chmod +x "$TMPDIR/kubectl" "$TMPDIR/gh" "$TMPDIR/docker"

output="$(PATH="$TMPDIR:$PATH" "$SCRIPT" --image "$IMAGE" --context dry-run-context --namespace stt-bench)"

assert_contains() {
  local needle="$1"
  if ! grep -Fq -- "$needle" <<<"$output"; then
    echo "expected preflight output to contain: $needle" >&2
    exit 1
  fi
}

assert_output_absent() {
  local needle="$1"
  if grep -Fq -- "$needle" <<<"$output"; then
    echo "preflight output must not contain: $needle" >&2
    exit 1
  fi
}

assert_contains "epoll preflight ok"
assert_contains "gh workflow run images.yml --ref"
assert_contains "-f image=ocaml-oxcaml-epoll"
assert_contains "scripts/bench/oxcaml_epoll_k3s_point.sh --context dry-run-context --namespace stt-bench --image $IMAGE --sessions 2200"
assert_output_absent "docker buildx build"
