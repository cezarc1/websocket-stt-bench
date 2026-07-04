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

cat >"$TMPDIR/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [ "${args[0]:-}" = "-C" ]; then
  args=("${args[@]:2}")
fi
case "${args[*]}" in
  "branch --show-current")
    printf 'codex/oxcaml-epoll-gateway'
    ;;
  "rev-parse HEAD")
    printf '4cd2c969df71c94fb587088a7bf70a95dfba5491'
    ;;
  "rev-parse --short=7 HEAD")
    printf '4cd2c96'
    ;;
  "status --porcelain")
    if [ "${OXCAML_EPOLL_TEST_GIT_DIRTY:-0}" = "1" ]; then
      printf ' M scripts/bench/oxcaml_epoll_preflight.sh\n'
    fi
    ;;
  *)
    echo "unexpected git invocation: $*" >&2
    exit 23
    ;;
esac
STUB

chmod +x "$TMPDIR/kubectl" "$TMPDIR/gh" "$TMPDIR/docker" "$TMPDIR/git"

output="$(PATH="$TMPDIR:$PATH" "$SCRIPT" --image "$IMAGE" --context dry-run-context --namespace stt-bench)"
head_sha="4cd2c969df71c94fb587088a7bf70a95dfba5491"
default_image="ghcr.io/cezarc1/websocket-stt-bench/ocaml-oxcaml-epoll:sha-4cd2c96"
default_output="$(PATH="$TMPDIR:$PATH" "$SCRIPT" --context dry-run-context --namespace stt-bench)"
just_default_output="$(PATH="$TMPDIR:$PATH" just --justfile "$ROOT/justfile" --working-directory "$ROOT" oxcaml-epoll-preflight)"

set +e
dirty_output="$(PATH="$TMPDIR:$PATH" OXCAML_EPOLL_TEST_GIT_DIRTY=1 "$SCRIPT" --context dry-run-context --namespace stt-bench 2>&1)"
dirty_rc=$?
set -e

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

if ! grep -Fq -- "scripts/bench/oxcaml_epoll_k3s_point.sh --context dry-run-context --namespace stt-bench --image $default_image --sessions 2200" <<<"$default_output"; then
  echo "expected default preflight output to use current commit image: $default_image" >&2
  exit 1
fi
if ! grep -Fq -- "Source commit: $head_sha" <<<"$default_output"; then
  echo "expected default preflight output to report the source commit" >&2
  exit 1
fi
if ! grep -Eq -- "Worktree state: (clean|dirty)" <<<"$default_output"; then
  echo "expected default preflight output to report clean or dirty worktree state" >&2
  exit 1
fi
if ! grep -Fq -- "scripts/bench/oxcaml_epoll_k3s_point.sh --namespace stt-bench --image $default_image --sessions 2200" <<<"$just_default_output"; then
  echo "expected just oxcaml-epoll-preflight to use default current commit image: $default_image" >&2
  exit 1
fi
if [ "$dirty_rc" -ne 2 ]; then
  echo "expected dirty default-image preflight to fail with status 2, got $dirty_rc" >&2
  echo "$dirty_output" >&2
  exit 1
fi
if ! grep -Fq -- "dirty worktree; commit changes before using the default sha image tag" <<<"$dirty_output"; then
  echo "expected dirty default-image preflight to explain the committed-HEAD requirement" >&2
  echo "$dirty_output" >&2
  exit 1
fi
