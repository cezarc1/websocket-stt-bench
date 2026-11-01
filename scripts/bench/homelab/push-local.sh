#!/usr/bin/env bash
# Build and push linux/amd64 images from this machine for the GHCR packages
# that GitHub Actions cannot write to (see local-builds.txt: image|dockerfile|args,
# generated from the images.yml matrix). Uses the existing `docker login ghcr.io`.
#   scripts/bench/homelab/push-local.sh <tag> [image ...]
# Elixir on Apple silicon: the Erlang JIT crashes under amd64 emulation during
# the BUILD stage, so the build stage gets ERL_FLAGS="+JMsingle true" via a
# temporary Dockerfile copy; the runtime stage (the shipped image) is unchanged.
set -uo pipefail
TAG=${1:?tag}; shift
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"
LIST="$REPO/scripts/bench/homelab/local-builds.txt"
TMPDF="$(mktemp -d)"
trap 'rm -rf "$TMPDF"' EXIT
fail=0
while IFS='|' read -r img df args; do
  [ -n "$img" ] || continue
  if [ "$#" -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$img"; then continue; fi
  extra=()
  if [ "$img" = elixir-phoenix ] && [ "$(uname -m)" = arm64 ]; then
    sed '1a\
ARG ERL_FLAGS
' "$df" > "$TMPDF/elixir.Dockerfile"
    df="$TMPDF/elixir.Dockerfile"; extra=(--build-arg "ERL_FLAGS=+JMsingle true")
  fi
  for attempt in 1 2; do
    echo "[$(date +%T)] build $img (attempt $attempt)"
    # shellcheck disable=SC2086
    if docker buildx build --platform linux/amd64 -f "$df" $args "${extra[@]}" \
         -t "ghcr.io/cezarc1/websocket-stt-bench/$img:$TAG" --push . > "$REPO/results/homelab/build-$img.log" 2>&1; then
      echo "[$(date +%T)] OK $img"; break
    fi
    echo "[$(date +%T)] FAIL $img: $(grep -m1 -E 'ERROR' "$REPO/results/homelab/build-$img.log" | cut -c1-200)"
    [ "$attempt" = 2 ] && fail=1
  done
done < "$LIST"
exit $fail
