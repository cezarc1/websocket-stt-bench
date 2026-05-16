#!/usr/bin/env bash
# Drive a session ladder against an in-cluster gateway, one point per arg.
#
#   SVC=<svc> PORT=<port> LABEL=<prefix> [CTX=..] [NS=..] \
#     scripts/bench/ladder.sh <s1> <s2> ...
#
# Divide-and-conquer protocol (see docs/RUNTIME_PLAYBOOK.md):
#   1. Coarse: a wide ladder to find the pass→fail transition.
#   2. Bisect that interval until pass and first-solid-fail are ~one
#      step apart.
#   3. Re-run the top passing point to CONFIRM (a 1-pass/1-fail point is
#      "borderline", not the headline number).
# Each line prints "<sessions> PASS|FAIL <reason> | <metrics>".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for s in "$@"; do
  echo "=== $(date +%H:%M:%S) point: $s sessions (LABEL=${LABEL:-?}) ==="
  bash "$HERE/run_point.sh" "$s" 2>&1 | tail -1
done
