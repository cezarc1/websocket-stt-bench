#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
# Pinned Eclipse Temurin 25 release, e.g. "25.0.1+9". The "+" delimits the
# feature.interim.update from the build number (Adoptium's release naming).
JDK_VERSION="$(version_value tools java_jdk)"
TOOLS_DIR="$ROOT/.tools"
BIN_DIR="$TOOLS_DIR/bin"
INSTALL_DIR="$TOOLS_DIR/jdk-$JDK_VERSION"
JAVA_BIN="$INSTALL_DIR/bin/java"

if [ -x "$JAVA_BIN" ]; then
  # Strip the "+build" suffix when comparing — `java -version` reports
  # "25.0.1" without the build number on the version line we grep here.
  installed="$("$JAVA_BIN" -version 2>&1 | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
  feature_interim_update="${JDK_VERSION%%+*}"
  if [ "$installed" = "$feature_interim_update" ]; then
    mkdir -p "$BIN_DIR"
    ln -sf "../jdk-$JDK_VERSION/bin/java" "$BIN_DIR/java"
    ln -sf "../jdk-$JDK_VERSION/bin/javac" "$BIN_DIR/javac"
    ln -sf "../jdk-$JDK_VERSION/bin/jar" "$BIN_DIR/jar"
    exit 0
  fi
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) os="mac"; arch="aarch64" ;;
  Darwin-x86_64) os="mac"; arch="x64" ;;
  Linux-aarch64 | Linux-arm64) os="linux"; arch="aarch64" ;;
  Linux-x86_64) os="linux"; arch="x64" ;;
  *)
    echo "unsupported platform for pinned jdk: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

# Adoptium release tag format: "jdk-25.0.1+9"
release_tag="jdk-$JDK_VERSION"
# Asset filename format: "OpenJDK25U-jdk_<arch>_<os>_hotspot_25.0.1_9.tar.gz"
file_version="${JDK_VERSION//+/_}"
url="https://github.com/adoptium/temurin25-binaries/releases/download/${release_tag}/OpenJDK25U-jdk_${arch}_${os}_hotspot_${file_version}.tar.gz"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading temurin $JDK_VERSION ${os}-${arch}" >&2
curl -fsSL "$url" -o "$tmp/jdk.tar.gz"
tar -C "$tmp" -xzf "$tmp/jdk.tar.gz"

# Temurin archives extract to a directory whose name we don't know up front,
# but it's the only top-level dir. On macOS the JDK is nested under
# Contents/Home; flatten that so $INSTALL_DIR/bin/java is uniform.
extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
if [ -d "$extracted/Contents/Home" ]; then
  extracted="$extracted/Contents/Home"
fi

rm -rf "$INSTALL_DIR"
mkdir -p "$TOOLS_DIR" "$BIN_DIR"
mv "$extracted" "$INSTALL_DIR"
ln -sf "../jdk-$JDK_VERSION/bin/java" "$BIN_DIR/java"
ln -sf "../jdk-$JDK_VERSION/bin/javac" "$BIN_DIR/javac"
ln -sf "../jdk-$JDK_VERSION/bin/jar" "$BIN_DIR/jar"

echo "installed temurin $JDK_VERSION to $JAVA_BIN" >&2
