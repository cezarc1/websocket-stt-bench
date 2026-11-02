#!/usr/bin/env bash
# One full homelab pass: conformance for every gateway on the exact images,
# then every 1-vCPU and 2-vCPU ceiling sweep.  scripts/bench/homelab/full-pass.sh <out-dir> [tag]
set -uo pipefail
OUT=${1:?out dir}; TAG=${2:-colocated-rerun}
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"; cd "$REPO"; mkdir -p "$OUT/1vcpu" "$OUT/2vcpu"
ONE="rustSync cpp23UWebsockets rust ocamlOxcamlEpoll javaHelidonNima typescriptBun goNethttp ocamlOxcaml ocamlWebsocketAsync scalaPekko elixir pythonGil pythonFt"
# Single-loop runtimes (OCaml, Bun) cannot use a second vCPU and are not swept at 2.
TWO="rustSync-2vcpu cpp23UWebsockets-2vcpu rust-2vcpu javaHelidonNima-2vcpu goNethttp-2vcpu scalaPekko-2vcpu elixir-2vcpu pythonGil-2vcpu pythonFt-2vcpu"
scripts/bench/homelab/conformance.sh "$TAG" > "$OUT/conformance.log" 2>&1
cat "$OUT/conformance.log"
ok=()
for k in $ONE; do
  svc=$(grep -E "^$k:" scripts/bench/homelab/conformance.sh | cut -d: -f2)
  if grep -q "$svc \.\.\. ok" "$OUT/conformance.log"; then ok+=("$k"); else echo "SKIP $k: conformance failed"; fi
done
two=()
for k in $TWO; do printf '%s\n' "${ok[@]}" | grep -qx "${k%-2vcpu}" && two+=("$k"); done
scripts/bench/homelab/sweep.py --out "$OUT/1vcpu" --image-tag "$TAG" "${ok[@]}" > "$OUT/sweep-1vcpu.log" 2>&1
scripts/bench/homelab/sweep.py --out "$OUT/2vcpu" --image-tag "$TAG" "${two[@]}" > "$OUT/sweep-2vcpu.log" 2>&1
grep RESULT "$OUT"/sweep-*.log
