#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"
MAVEN_VERSION="$(version_value tools maven)"
TOOLS_DIR="$ROOT/.tools"
BIN_DIR="$TOOLS_DIR/bin"
INSTALL_DIR="$TOOLS_DIR/apache-maven-$MAVEN_VERSION"
MVN_BIN="$INSTALL_DIR/bin/mvn"

if [ -x "$MVN_BIN" ]; then
  installed="$("$MVN_BIN" -version | awk 'NR == 1 {print $3}')"
  if [ "$installed" = "$MAVEN_VERSION" ]; then
    mkdir -p "$BIN_DIR"
    ln -sf "../apache-maven-$MAVEN_VERSION/bin/mvn" "$BIN_DIR/mvn"
    exit 0
  fi
fi

case "$MAVEN_VERSION" in
  3.*) major_path="maven-3" ;;
  4.*) major_path="maven-4" ;;
  *)
    echo "unsupported maven version: $MAVEN_VERSION" >&2
    exit 1
    ;;
esac

archive="apache-maven-$MAVEN_VERSION-bin.tar.gz"
primary_url="https://dlcdn.apache.org/maven/${major_path}/${MAVEN_VERSION}/binaries/${archive}"
fallback_url="https://archive.apache.org/dist/maven/${major_path}/${MAVEN_VERSION}/binaries/${archive}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading maven $MAVEN_VERSION" >&2
if ! curl -fsSL "$primary_url" -o "$tmp/maven.tar.gz"; then
  curl -fsSL "$fallback_url" -o "$tmp/maven.tar.gz"
fi
tar -C "$tmp" -xzf "$tmp/maven.tar.gz"

rm -rf "$INSTALL_DIR"
mkdir -p "$TOOLS_DIR" "$BIN_DIR"
mv "$tmp/apache-maven-$MAVEN_VERSION" "$INSTALL_DIR"
ln -sf "../apache-maven-$MAVEN_VERSION/bin/mvn" "$BIN_DIR/mvn"

echo "installed maven $MAVEN_VERSION to $MVN_BIN" >&2
