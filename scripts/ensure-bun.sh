#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
BUN_VERSION="$(version_value tools bun)"
TOOLS_DIR="$ROOT/.tools"
BIN_DIR="$TOOLS_DIR/bin"
INSTALL_DIR="$TOOLS_DIR/bun-$BUN_VERSION"
BUN_BIN="$INSTALL_DIR/bun"

if [ -x "$BUN_BIN" ] && [ "$("$BUN_BIN" --version)" = "$BUN_VERSION" ]; then
  mkdir -p "$BIN_DIR"
  ln -sf "../bun-$BUN_VERSION/bun" "$BIN_DIR/bun"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform="darwin-aarch64" ;;
  Darwin-x86_64) platform="darwin-x64" ;;
  Linux-aarch64 | Linux-arm64) platform="linux-aarch64" ;;
  Linux-x86_64) platform="linux-x64" ;;
  *)
    echo "unsupported platform for pinned bun: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url="https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/bun-$platform.zip"
echo "downloading bun $BUN_VERSION $platform" >&2
curl -fsSL "$url" -o "$tmp/bun.zip"
unzip -q "$tmp/bun.zip" -d "$tmp"

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
mv "$tmp/bun-$platform/bun" "$BUN_BIN"
chmod +x "$BUN_BIN"
ln -sf "../bun-$BUN_VERSION/bun" "$BIN_DIR/bun"

echo "installed bun $BUN_VERSION to $BUN_BIN" >&2
