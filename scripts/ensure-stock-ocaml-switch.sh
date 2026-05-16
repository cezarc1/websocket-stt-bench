#!/usr/bin/env bash
# Create the pinned stock-OCaml opam switch and install the Async gateway
# dependencies. Set OCAML_STOCK_SWITCH=default to reuse an existing
# local stock switch whose compiler is already the pinned version.
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
OCAML_VERSION="$(version_value ocaml_stock version)"
OCAML_SWITCH="${OCAML_STOCK_SWITCH:-$(version_value ocaml_stock opam_switch)}"
OPAM="$ROOT/.tools/bin/opam"

if [ ! -x "$OPAM" ]; then
  echo "opam not installed yet; run: just ensure-opam" >&2
  exit 1
fi

if [ ! -d "${OPAMROOT:-$HOME/.opam}" ]; then
  "$OPAM" init --bare --disable-sandboxing --no-setup --yes
fi

if ! "$OPAM" switch list --short 2>/dev/null | grep -qx "$OCAML_SWITCH"; then
  echo "creating stock OCaml switch $OCAML_SWITCH ($OCAML_VERSION)" >&2
  "$OPAM" switch create "$OCAML_SWITCH" "ocaml-base-compiler.$OCAML_VERSION" --yes
fi

actual="$("$OPAM" exec --switch "$OCAML_SWITCH" -- ocamlc -version)"
if [ "$actual" != "$OCAML_VERSION" ]; then
  echo "stock OCaml switch $OCAML_SWITCH: expected compiler $OCAML_VERSION, got $actual" >&2
  exit 1
fi

declare -a packages=(
  "ocamlformat.$(version_value ocaml_stock.dependencies ocamlformat)"
  dune
  core
  core_unix
  async
  yojson
  ppx_jane
  alcotest
)

echo "installing stock OCaml packages into switch $OCAML_SWITCH" >&2
"$OPAM" install --switch "$OCAML_SWITCH" --yes "${packages[@]}"

echo "stock OCaml switch $OCAML_SWITCH ready" >&2
