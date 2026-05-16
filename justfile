set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

doctor:
    bash scripts/ensure-uv.sh
    bash scripts/ensure-bun.sh
    bash scripts/ensure-go.sh
    bash scripts/ensure-jdk.sh
    bash scripts/ensure-maven.sh
    bash scripts/ensure-sbt.sh
    bash scripts/ensure-bazelisk.sh
    bash scripts/ensure-opam.sh
    bash scripts/doctor.sh
    bash scripts/check-docker-tags.sh

ensure-uv:
    bash scripts/ensure-uv.sh

ensure-bun:
    bash scripts/ensure-bun.sh

ensure-go:
    bash scripts/ensure-go.sh

ensure-jdk:
    bash scripts/ensure-jdk.sh

ensure-maven:
    bash scripts/ensure-maven.sh

ensure-sbt:
    bash scripts/ensure-sbt.sh

ensure-bazelisk:
    bash scripts/ensure-bazelisk.sh

ensure-opam:
    bash scripts/ensure-opam.sh

# Slow on first run (10-20 min): builds the OxCaml compiler from source.
# Skipped by `just doctor` because that recipe should stay fast.
ensure-oxcaml-switch: ensure-opam
    bash scripts/ensure-oxcaml-switch.sh

py-lock: ensure-uv
    bash scripts/py-sync.sh lock

py-sync: ensure-uv
    bash scripts/py-sync.sh sync

analysis-lock: ensure-uv
    cd analysis && ../.tools/bin/uv lock

analysis-sync: ensure-uv
    cd analysis && ../.tools/bin/uv sync --locked

analysis-test: analysis-sync
    cd analysis && ../.tools/bin/uv run pytest tests/ -q

analysis-check: analysis-sync analysis-test
    cd analysis && ../.tools/bin/uv run ruff format --check .
    cd analysis && ../.tools/bin/uv run ruff check .
    cd analysis && ../.tools/bin/uv run ty check

py-test: py-sync
    cd services/python-fastapi && PYTHONPATH=. ../../.tools/bin/uv run pytest tests/ -q

python-check: py-sync py-test
    cd services/python-fastapi && ../../.tools/bin/uv run ruff format --check .
    cd services/python-fastapi && ../../.tools/bin/uv run ruff check .
    cd services/python-fastapi && ../../.tools/bin/uv run ty check

ts-install: ensure-bun
    cd services/typescript-bun && PATH="$PWD/../../.tools/bin:$PATH" ../../.tools/bin/bun install --frozen-lockfile

ts-check: ts-install
    cd services/typescript-bun && PATH="$PWD/../../.tools/bin:$PATH" ../../.tools/bin/bun run check

go-tools: ensure-go
    GOBIN="$PWD/.tools/bin" .tools/bin/go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v"$(awk -F\" '/golangci_lint =/{print $2; exit}' versions.lock.toml)"
    GOBIN="$PWD/.tools/bin" .tools/bin/go install mvdan.cc/gofumpt@v"$(awk -F\" '/gofumpt =/{print $2; exit}' versions.lock.toml)"
    GOBIN="$PWD/.tools/bin" .tools/bin/go install golang.org/x/tools/cmd/goimports@v"$(awk -F\" '/goimports =/{print $2; exit}' versions.lock.toml)"
    GOBIN="$PWD/.tools/bin" .tools/bin/go install golang.org/x/vuln/cmd/govulncheck@v"$(awk -F\" '/govulncheck =/{print $2; exit}' versions.lock.toml)"

go-check: go-tools
    cd services/go-nethttp && test -z "$(../../.tools/bin/gofumpt -l .)"
    cd services/go-nethttp && test -z "$(../../.tools/bin/goimports -l .)"
    cd services/go-nethttp && ../../.tools/bin/go mod tidy -diff
    cd services/go-nethttp && ../../.tools/bin/go vet ./...
    cd services/go-nethttp && PATH="$PWD/../../.tools/bin:$PATH" ../../.tools/bin/golangci-lint run ./...
    cd services/go-nethttp && ../../.tools/bin/govulncheck ./...
    cd services/go-nethttp && ../../.tools/bin/go test ./...
    cd services/go-nethttp && ../../.tools/bin/go test -race ./...

# Resolve Maven deps once so iterative checks don't redownload.
java-deps: ensure-jdk ensure-maven
    cd services/java-helidon-nima && JAVA_HOME="$PWD/../../.tools/jdk-$(awk -F\" '/java_jdk =/{print $2; exit}' ../../versions.lock.toml)" ../../.tools/bin/mvn -B -q -DskipTests dependency:go-offline

# `mvn verify` runs the full per-language gate: Spotless format check,
# Error Prone + NullAway, compile, tests, Maven Enforcer.
java-check: ensure-jdk ensure-maven
    cd services/java-helidon-nima && JAVA_HOME="$PWD/../../.tools/jdk-$(awk -F\" '/java_jdk =/{print $2; exit}' ../../versions.lock.toml)" ../../.tools/bin/mvn -B verify

java-test: ensure-jdk ensure-maven
    cd services/java-helidon-nima && JAVA_HOME="$PWD/../../.tools/jdk-$(awk -F\" '/java_jdk =/{print $2; exit}' ../../versions.lock.toml)" ../../.tools/bin/mvn -B test

java-lock: ensure-jdk ensure-maven
    cd services/java-helidon-nima && JAVA_HOME="$PWD/../../.tools/jdk-$(awk -F\" '/java_jdk =/{print $2; exit}' ../../versions.lock.toml)" ../../.tools/bin/mvn -B -DskipTests dependency:resolve dependency:resolve-plugins

scala-deps: ensure-jdk ensure-sbt
    cd services/scala-pekko && JAVA_HOME="$PWD/../../.tools/jdk-$(awk -F\" '/java_jdk =/{print $2; exit}' ../../versions.lock.toml)" ../../.tools/bin/sbt -batch update

# `sbt verify` runs the full per-language gate: scalafmt format check,
# scalafix lint, strict compile (-Werror -Wunused:all), tests via MUnit.
scala-check: ensure-jdk ensure-sbt
    cd services/scala-pekko && JAVA_HOME="$PWD/../../.tools/jdk-$(awk -F\" '/java_jdk =/{print $2; exit}' ../../versions.lock.toml)" ../../.tools/bin/sbt -batch "scalafmtCheckAll; scalafixAll --check; compile; test"

scala-test: ensure-jdk ensure-sbt
    cd services/scala-pekko && JAVA_HOME="$PWD/../../.tools/jdk-$(awk -F\" '/java_jdk =/{print $2; exit}' ../../versions.lock.toml)" ../../.tools/bin/sbt -batch test

scala-lock: ensure-jdk ensure-sbt
    cd services/scala-pekko && JAVA_HOME="$PWD/../../.tools/jdk-$(awk -F\" '/java_jdk =/{print $2; exit}' ../../versions.lock.toml)" ../../.tools/bin/sbt -batch update

py-bench: py-sync
    mkdir -p results
    cd services/python-fastapi && PYTHONPATH=. ../../.tools/bin/uv run python tests/bench_stub.py -o ../../results/python-bench-stub.json

py-bench-threading: py-sync
    mkdir -p results
    cd services/python-fastapi && PYTHONPATH=. ../../.tools/bin/uv run python -X gil=0 tests/bench_threading.py | tee ../../results/python-bench-threading-nogil.txt
    cd services/python-fastapi && PYTHONPATH=. ../../.tools/bin/uv run python -X gil=1 tests/bench_threading.py | tee ../../results/python-bench-threading-gil.txt

elixir-deps:
    cd services/elixir-phoenix && mix deps.get --locked

elixir-lock:
    cd services/elixir-phoenix && mix deps.get

elixir-check: elixir-deps
    cd services/elixir-phoenix && mix format --check-formatted
    cd services/elixir-phoenix && mix credo --strict
    cd services/elixir-phoenix && mix dialyzer
    cd services/elixir-phoenix && mix test

rust-tools:
    cargo install cargo-nextest --version "$(awk -F\" '/cargo_nextest =/{print $2; exit}' versions.lock.toml)" --locked
    cargo install cargo-deny --version "$(awk -F\" '/cargo_deny =/{print $2; exit}' versions.lock.toml)" --locked

rust-lock:
    cargo generate-lockfile

rust-check:
    cargo fmt --check
    cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
    cargo nextest run --workspace --all-features --locked
    cargo deny check

# `bazel fetch //...` resolves every transitive dep from MODULE.bazel.lock and
# caches the hermetic Clang 21 toolchain. Slow first run (~500 MB download);
# subsequent calls are no-ops.
cpp-deps: ensure-bazelisk
    cd services/cpp23-uwebsockets && ../../.tools/bin/bazel fetch //...

# Regenerate MODULE.bazel.lock after bumping any bazel_dep version pin.
cpp-lock: ensure-bazelisk
    cd services/cpp23-uwebsockets && ../../.tools/bin/bazel mod deps --lockfile_mode=update

# `bazel build` enforces the strict scalacOptions equivalent (-Werror -Wall
# -Wextra -Wpedantic -Wconversion ...) declared in .bazelrc. clang-tidy is
# wired as a Bazel aspect on a tidy config; clang-format checks formatting.
cpp-check: ensure-bazelisk
    cd services/cpp23-uwebsockets && ../../.tools/bin/bazel build --config=opt //:stt-cpp23-uwebsockets
    cd services/cpp23-uwebsockets && ../../.tools/bin/bazel test //...

cpp-test: ensure-bazelisk
    cd services/cpp23-uwebsockets && ../../.tools/bin/bazel test //...

# OCaml / OxCaml gateway. Local builds run inside the OxCaml opam switch
# created by `just ensure-oxcaml-switch`. The Dockerfile reproduces this
# environment hermetically for `just compose-build`.
ocaml-deps: ensure-oxcaml-switch
    cd services/ocaml-oxcaml && opam exec --switch "$(awk -F\" '/oxcaml_switch =/{print $2; exit}' ../../versions.lock.toml)" -- dune build @check --root .

ocaml-check: ensure-oxcaml-switch
    cd services/ocaml-oxcaml && opam exec --switch "$(awk -F\" '/oxcaml_switch =/{print $2; exit}' ../../versions.lock.toml)" -- dune build @fmt --root .
    cd services/ocaml-oxcaml && opam exec --switch "$(awk -F\" '/oxcaml_switch =/{print $2; exit}' ../../versions.lock.toml)" -- dune build --profile release --root .
    cd services/ocaml-oxcaml && opam exec --switch "$(awk -F\" '/oxcaml_switch =/{print $2; exit}' ../../versions.lock.toml)" -- dune runtest --root .

ocaml-test: ensure-oxcaml-switch
    cd services/ocaml-oxcaml && opam exec --switch "$(awk -F\" '/oxcaml_switch =/{print $2; exit}' ../../versions.lock.toml)" -- dune runtest --root .

ocaml-fmt: ensure-oxcaml-switch
    cd services/ocaml-oxcaml && opam exec --switch "$(awk -F\" '/oxcaml_switch =/{print $2; exit}' ../../versions.lock.toml)" -- dune build @fmt --auto-promote --root .

check: doctor python-check analysis-check ts-check go-check elixir-check rust-check java-check scala-check cpp-check ocaml-check

bench-ladder service_name service_url:
    # Build the loadgen with full release optimization ONCE up front. Running
    # the loadgen in debug mode would actively distort the latencies it's
    # measuring (Instant::now, HDR histograms, frame generation are all on
    # the hot path).
    cargo build --locked --release -p stt-loadgen
    for sessions in 50 100 250 500 1000 2000; do \
      for repeat in 1 2 3; do \
        mkdir -p results; \
        base="results/{{service_name}}-${sessions}s-15w-90m-r${repeat}"; \
        ./target/release/stt-loadgen \
          --url "{{service_url}}" \
          --service-name "{{service_name}}" \
          --sessions "$sessions" \
          --warmup-secs 15 \
          --measure-secs 90 \
          --repeat "$repeat" \
          --samples-out "${base}.samples.csv" \
          | tee "${base}.summary.json"; \
      done; \
    done

analyze-results input out:
    root="$PWD"; cd analysis && ../.tools/bin/uv run python -m stt_analysis --input "$root/{{input}}" --out "$root/{{out}}"

# Default error budget: 1e-5 (≈ 1 failure per 100k partial round-trips).
# Tolerates the kernel/TCP noise floor we measured (~10⁻⁶) while remaining
# ≥2 orders of magnitude tighter than realistic production SLOs. Override
# via `analyze-results-slo-budget` for strict-zero (0) or other values.
analyze-results-slo input out profile="balanced-realtime" multi_cpus="4":
    root="$PWD"; cd analysis && ../.tools/bin/uv run python -m stt_analysis --input "$root/{{input}}" --out "$root/{{out}}" --slo-profile "{{profile}}" --max-error-rate "0.00001" --multi-cpus "{{multi_cpus}}"

analyze-results-slo-budget input out max_error_rate profile="balanced-realtime" multi_cpus="4":
    root="$PWD"; cd analysis && ../.tools/bin/uv run python -m stt_analysis --input "$root/{{input}}" --out "$root/{{out}}" --slo-profile "{{profile}}" --max-error-rate "{{max_error_rate}}" --multi-cpus "{{multi_cpus}}"

compose-build:
    docker compose --profile single --profile multi --profile loadgen build

conformance: compose-build
    cleanup() { docker compose --profile single --profile loadgen down; }; \
    trap cleanup EXIT; \
    docker compose --profile single up -d --no-build \
      rust-axum-single \
      elixir-phoenix-single \
      python-fastapi-stock-single \
      python-fastapi-mt-single \
      typescript-bun-single \
      go-nethttp-single \
      java-helidon-nima-single \
      scala-pekko-single \
      cpp23-uwebsockets-single \
      ocaml-oxcaml-single; \
    docker compose --profile loadgen run --rm --no-deps \
      --entrypoint /usr/local/bin/stt-conformance \
      loadgen \
      --service rust-axum-single=ws://rust-axum-single:3000/ws/stt \
      --service elixir-phoenix-single=ws://elixir-phoenix-single:4000/ws/stt \
      --service python-fastapi-stock-single=ws://python-fastapi-stock-single:8000/ws/stt \
      --service python-fastapi-mt-single=ws://python-fastapi-mt-single:8000/ws/stt \
      --service typescript-bun-single=ws://typescript-bun-single:7000/ws/stt \
      --service go-nethttp-single=ws://go-nethttp-single:6000/ws/stt \
      --service java-helidon-nima-single=ws://java-helidon-nima-single:5000/ws/stt \
      --service scala-pekko-single=ws://scala-pekko-single:2500/ws/stt \
      --service cpp23-uwebsockets-single=ws://cpp23-uwebsockets-single:1500/ws/stt \
      --service ocaml-oxcaml-single=ws://ocaml-oxcaml-single:9000/ws/stt

compose-single:
    docker compose --profile single up --build

compose-multi:
    docker compose --profile multi up --build
