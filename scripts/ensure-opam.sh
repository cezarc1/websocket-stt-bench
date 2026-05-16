#!/usr/bin/env bash
# Install pinned opam binary into .tools/bin/opam.
#
# opam itself does not require a switch; it manages switches. We pin opam's
# own version in versions.lock.toml [ocaml] opam so that switch-creation
# behavior is reproducible. The OxCaml switch creation happens in
# ensure-oxcaml-switch.sh.
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
OPAM_VERSION="$(version_value ocaml opam)"
TOOLS_DIR="$ROOT/.tools"
BIN_DIR="$TOOLS_DIR/bin"
INSTALL_DIR="$TOOLS_DIR/opam-$OPAM_VERSION"
OPAM_BIN="$INSTALL_DIR/opam"

if [ -x "$OPAM_BIN" ] && [ "$("$OPAM_BIN" --version 2>/dev/null | head -n1)" = "$OPAM_VERSION" ]; then
  mkdir -p "$BIN_DIR"
  ln -sf "../opam-$OPAM_VERSION/opam" "$BIN_DIR/opam"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) asset="opam-${OPAM_VERSION}-arm64-macos" ;;
  Darwin-x86_64) asset="opam-${OPAM_VERSION}-x86_64-macos" ;;
  Linux-aarch64 | Linux-arm64) asset="opam-${OPAM_VERSION}-arm64-linux" ;;
  Linux-x86_64) asset="opam-${OPAM_VERSION}-x86_64-linux" ;;
  *)
    echo "unsupported platform for pinned opam: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url="https://github.com/ocaml/opam/releases/download/${OPAM_VERSION}/${asset}"
echo "downloading opam $OPAM_VERSION ($asset)" >&2
curl -fsSL "$url" -o "$tmp/opam"

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
mv "$tmp/opam" "$OPAM_BIN"
chmod +x "$OPAM_BIN"
ln -sf "../opam-$OPAM_VERSION/opam" "$BIN_DIR/opam"

echo "installed opam $OPAM_VERSION to $OPAM_BIN" >&2
