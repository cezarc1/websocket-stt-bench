#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

ROOT="$(repo_root)"

expect_version() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [ "$actual" != "$expected" ]; then
    echo "$label: expected $expected, got $actual" >&2
    exit 1
  fi
}

JUST_EXPECTED="$(version_value tools just)"
UV_EXPECTED="$(version_value tools uv)"
RUST_EXPECTED="$(version_value tools rust)"
BUN_EXPECTED="$(version_value tools bun)"
GO_EXPECTED="$(version_value tools go)"
MAVEN_EXPECTED="$(version_value tools maven)"
PY_EXPECTED="$(version_value python version)"
PYENV_NAME="$(version_value python pyenv)"
PY_EXE="$(version_value python executable)"
ELIXIR_EXPECTED="$(version_value elixir version)"
OTP_EXPECTED="$(version_value elixir otp)"
JDK_EXPECTED="$(version_value tools java_jdk)"
SBT_EXPECTED="$(version_value tools sbt)"
BAZELISK_EXPECTED="$(version_value tools bazelisk)"

expect_version "$(just --version | awk '{print $2}')" "$JUST_EXPECTED" "just"
expect_version "$("$ROOT/.tools/bin/uv" --version | awk '{print $2}')" "$UV_EXPECTED" "uv"
expect_version "$(rustc --version | awk '{print $2}')" "$RUST_EXPECTED" "rustc"
expect_version "$(cargo --version | awk '{print $2}')" "$RUST_EXPECTED" "cargo"
expect_version "$("$ROOT/.tools/bin/bun" --version)" "$BUN_EXPECTED" "bun"
expect_version "$("$ROOT/.tools/bin/go" version | awk '{print $3}' | sed 's/^go//')" "$GO_EXPECTED" "go"
expect_version "$("$ROOT/.tools/bin/mvn" -version | awk 'NR == 1 {print $3}')" "$MAVEN_EXPECTED" "maven"

PYTHON_BIN="$(PYENV_VERSION="$PYENV_NAME" pyenv which "$PY_EXE")"
PYENV_VERSION="$PYENV_NAME" "$PYTHON_BIN" - "$PY_EXPECTED" <<'PY'
import sys
import sysconfig

expected = tuple(int(part) for part in sys.argv[1].split("."))
actual = sys.version_info[:3]
if actual != expected:
    raise SystemExit(f"python: expected {expected}, got {actual}")
if sysconfig.get_config_var("Py_GIL_DISABLED") != 1:
    raise SystemExit("python: expected Py_GIL_DISABLED=1")
if not hasattr(sys, "_is_gil_enabled"):
    raise SystemExit("python: expected sys._is_gil_enabled")
if sys._is_gil_enabled():
    raise SystemExit("python: expected free-threading GIL disabled")
PY

ELIXIR_VERSION="$(elixir -e 'IO.write(System.version())')"
expect_version "$ELIXIR_VERSION" "$ELIXIR_EXPECTED" "elixir"

OTP_VERSION="$(elixir -e 'otp = :erlang.system_info(:otp_release) |> List.to_string(); path = Path.join([:code.root_dir() |> List.to_string(), "releases", otp, "OTP_VERSION"]); case File.read(path) do {:ok, value} -> IO.write(String.trim(value)); _ -> IO.write(otp) end')"
expect_version "$OTP_VERSION" "$OTP_EXPECTED" "erlang/otp"

if command -v cargo-nextest >/dev/null 2>&1; then
  cargo nextest --version | grep -q "cargo-nextest $(version_value tools cargo_nextest)" || {
    echo "cargo-nextest: expected $(version_value tools cargo_nextest)" >&2
    exit 1
  }
else
  echo "cargo-nextest is not installed; run: just rust-tools" >&2
  exit 1
fi

if command -v cargo-deny >/dev/null 2>&1; then
  cargo deny --version | grep -q "cargo-deny $(version_value tools cargo_deny)" || {
    echo "cargo-deny: expected $(version_value tools cargo_deny)" >&2
    exit 1
  }
else
  echo "cargo-deny is not installed; run: just rust-tools" >&2
  exit 1
fi

# `java -version` reports the "<feature>.<interim>.<update>" without the build
# number, so compare only that prefix of the pinned "<feature>.<interim>.<update>+<build>".
JAVA_BIN="$ROOT/.tools/bin/java"
if [ ! -x "$JAVA_BIN" ]; then
  echo "java: missing $JAVA_BIN; run: just ensure-jdk" >&2
  exit 1
fi
JAVA_ACTUAL="$("$JAVA_BIN" -version 2>&1 | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
expect_version "$JAVA_ACTUAL" "${JDK_EXPECTED%%+*}" "java"

SBT_BIN="$ROOT/.tools/bin/sbt"
if [ ! -x "$SBT_BIN" ]; then
  echo "sbt: missing $SBT_BIN; run: just ensure-sbt" >&2
  exit 1
fi
SBT_ACTUAL="$("$SBT_BIN" --numeric-version 2>/dev/null | tail -n1 | tr -d '[:space:]')"
expect_version "$SBT_ACTUAL" "$SBT_EXPECTED" "sbt"

BAZEL_BIN="$ROOT/.tools/bin/bazel"
if [ ! -x "$BAZEL_BIN" ]; then
  echo "bazelisk: missing $BAZEL_BIN; run: just ensure-bazelisk" >&2
  exit 1
fi
# bazelisk reports as "Bazelisk version: 1.29.0" (or "v1.29.0" on some releases).
BAZELISK_ACTUAL="$("$BAZEL_BIN" --version 2>/dev/null | awk '/^Bazelisk version:/ { print $3 }' | sed 's/^v//')"
expect_version "$BAZELISK_ACTUAL" "$BAZELISK_EXPECTED" "bazelisk"

docker version --format '{{.Client.Version}}' >/dev/null
echo "doctor ok"
