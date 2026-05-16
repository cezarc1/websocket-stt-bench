#!/usr/bin/env bash
set -euo pipefail

# Pinned bazelisk launcher in `.tools/bazelisk-$VERSION/bazel`, symlinked from
# `.tools/bin/bazel`. Same layout as ensure-bun.sh / ensure-go.sh / ensure-jdk.sh.

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
BAZELISK_VERSION="$(version_value tools bazelisk)"
TOOLS_DIR="$ROOT/.tools"
BIN_DIR="$TOOLS_DIR/bin"
INSTALL_DIR="$TOOLS_DIR/bazelisk-$BAZELISK_VERSION"
BAZEL_BIN="$INSTALL_DIR/bazel"

# bazelisk reports its version with `--version`, e.g. "Bazelisk version: 1.29.0".
if [ -x "$BAZEL_BIN" ]; then
  installed="$("$BAZEL_BIN" --version 2>/dev/null | awk '/^Bazelisk version:/ { print $3 }')"
  if [ "$installed" = "v$BAZELISK_VERSION" ] || [ "$installed" = "$BAZELISK_VERSION" ]; then
    mkdir -p "$BIN_DIR"
    ln -sf "../bazelisk-$BAZELISK_VERSION/bazel" "$BIN_DIR/bazel"
    exit 0
  fi
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) asset="bazelisk-darwin-arm64" ;;
  Darwin-x86_64) asset="bazelisk-darwin-amd64" ;;
  Linux-aarch64 | Linux-arm64) asset="bazelisk-linux-arm64" ;;
  Linux-x86_64) asset="bazelisk-linux-amd64" ;;
  *)
    echo "unsupported platform for pinned bazelisk: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

url="https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/${asset}"

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "downloading bazelisk $BAZELISK_VERSION ($asset)" >&2
curl -fsSL "$url" -o "$tmp"
chmod +x "$tmp"
mv "$tmp" "$BAZEL_BIN"
ln -sf "../bazelisk-$BAZELISK_VERSION/bazel" "$BIN_DIR/bazel"
trap - EXIT

echo "installed bazelisk $BAZELISK_VERSION to $BAZEL_BIN" >&2
