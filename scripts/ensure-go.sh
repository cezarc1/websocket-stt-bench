#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
GO_VERSION="$(version_value tools go)"
TOOLS_DIR="$ROOT/.tools"
BIN_DIR="$TOOLS_DIR/bin"
INSTALL_DIR="$TOOLS_DIR/go-$GO_VERSION"
GO_BIN="$INSTALL_DIR/bin/go"

if [ -x "$GO_BIN" ] && [ "$("$GO_BIN" version | awk '{print $3}')" = "go$GO_VERSION" ]; then
  mkdir -p "$BIN_DIR"
  ln -sf "../go-$GO_VERSION/bin/go" "$BIN_DIR/go"
  ln -sf "../go-$GO_VERSION/bin/gofmt" "$BIN_DIR/gofmt"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform="darwin-arm64" ;;
  Darwin-x86_64) platform="darwin-amd64" ;;
  Linux-aarch64 | Linux-arm64) platform="linux-arm64" ;;
  Linux-x86_64) platform="linux-amd64" ;;
  *)
    echo "unsupported platform for pinned go: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url="https://go.dev/dl/go$GO_VERSION.$platform.tar.gz"
echo "downloading go $GO_VERSION $platform" >&2
curl -fsSL "$url" -o "$tmp/go.tar.gz"
tar -C "$tmp" -xzf "$tmp/go.tar.gz"

rm -rf "$INSTALL_DIR"
mkdir -p "$TOOLS_DIR" "$BIN_DIR"
mv "$tmp/go" "$INSTALL_DIR"
ln -sf "../go-$GO_VERSION/bin/go" "$BIN_DIR/go"
ln -sf "../go-$GO_VERSION/bin/gofmt" "$BIN_DIR/gofmt"

echo "installed go $GO_VERSION to $GO_BIN" >&2
