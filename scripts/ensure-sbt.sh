#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
SBT_VERSION="$(version_value tools sbt)"
TOOLS_DIR="$ROOT/.tools"
BIN_DIR="$TOOLS_DIR/bin"
INSTALL_DIR="$TOOLS_DIR/sbt-$SBT_VERSION"
SBT_BIN="$INSTALL_DIR/bin/sbt"

if [ -x "$SBT_BIN" ]; then
  installed="$("$SBT_BIN" --numeric-version 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  if [ "$installed" = "$SBT_VERSION" ]; then
    mkdir -p "$BIN_DIR"
    ln -sf "../sbt-$SBT_VERSION/bin/sbt" "$BIN_DIR/sbt"
    exit 0
  fi
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url="https://github.com/sbt/sbt/releases/download/v${SBT_VERSION}/sbt-${SBT_VERSION}.tgz"
echo "downloading sbt $SBT_VERSION" >&2
curl -fsSL "$url" -o "$tmp/sbt.tgz"
tar -C "$tmp" -xzf "$tmp/sbt.tgz"

rm -rf "$INSTALL_DIR"
mkdir -p "$TOOLS_DIR" "$BIN_DIR"
mv "$tmp/sbt" "$INSTALL_DIR"
ln -sf "../sbt-$SBT_VERSION/bin/sbt" "$BIN_DIR/sbt"

echo "installed sbt $SBT_VERSION to $SBT_BIN" >&2
