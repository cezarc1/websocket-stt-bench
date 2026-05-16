#!/usr/bin/env bash
# Create the pinned OxCaml opam switch and install all OCaml gateway
# dependencies. Idempotent: if the switch exists and reports the right
# compiler version, only `opam install` runs to converge package state.
#
# Cold-start cost on a typical workstation:
# - OxCaml switch creation from source: 10-20 minutes (compiles the
#   modified OCaml compiler).
# - Package installs (ocamlformat, merlin, parallel, async_websocket,
#   h2, yojson, ppx_jane, ppx_expect, alcotest, ...): another 5-10
#   minutes the first time.
#
# After that, the switch is cached under $OPAMROOT.
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
OXCAML_SWITCH="$(version_value ocaml oxcaml_switch)"
OXCAML_REPO_COMMIT="$(version_value ocaml oxcaml_repo_commit)"
OPAM="$ROOT/.tools/bin/opam"

if [ ! -x "$OPAM" ]; then
  echo "opam not installed yet; run: just ensure-opam" >&2
  exit 1
fi

# Initialize the user-level opam root if needed. Don't touch global state
# already configured by the user.
if [ ! -d "${OPAMROOT:-$HOME/.opam}" ]; then
  "$OPAM" init --bare --disable-sandboxing --no-setup --yes
fi

ox_repo_url="git+https://github.com/oxcaml/opam-repository.git"
if [ "$OXCAML_REPO_COMMIT" != "main" ]; then
  ox_repo_url="${ox_repo_url}#${OXCAML_REPO_COMMIT}"
fi

# Switch creation is the slow path. Skip if the switch already exists with
# the right compiler.
if ! "$OPAM" switch list --short 2>/dev/null | grep -qx "$OXCAML_SWITCH"; then
  echo "creating OxCaml switch $OXCAML_SWITCH from $ox_repo_url" >&2
  "$OPAM" switch create "$OXCAML_SWITCH" \
    --repos "ox=$ox_repo_url,default" \
    --yes
fi

# Install developer tooling + libs into the OxCaml switch. We don't pin
# specific versions here because the OxCaml repo's invariant pins many of
# these to "+ox" variants that diverge from upstream version numbers
# (e.g., alcotest ships as 1.9.0+ox under the switch). Letting opam
# resolve picks the OxCaml-blessed flavor automatically.
declare -a packages=(
  ocamlformat
  merlin
  ocaml-lsp-server
  dune
  base
  core
  core_unix
  async
  parallel
  yojson
  ppx_jane
  alcotest
)

echo "installing OCaml packages into switch $OXCAML_SWITCH" >&2
"$OPAM" install --switch "$OXCAML_SWITCH" --yes "${packages[@]}"

echo "OxCaml switch $OXCAML_SWITCH ready" >&2
