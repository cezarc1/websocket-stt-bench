# Gateway image. Assumes the stable base image
# `stt-bench-oxcaml-base:5.2.0-ox` has already been built once via
# `docker build -f docker/ocaml-oxcaml-base.Dockerfile -t stt-bench-oxcaml-base:5.2.0-ox .`
# (also surfaced as `just ocaml-base-build`). The base carries the OxCaml
# switch + the full opam dep set, so this Dockerfile only does the fast
# bits: copy source, dune build, stage a slim runtime.

ARG BASE_IMAGE=stt-bench-oxcaml-base:5.2.0-ox
ARG DEBIAN_RUNTIME_IMAGE=debian:12-slim

FROM ${BASE_IMAGE} AS build

WORKDIR /app
COPY services/ocaml-oxcaml/dune-project ./dune-project
COPY services/ocaml-oxcaml/.ocamlformat ./.ocamlformat
COPY services/ocaml-oxcaml/lib ./lib
COPY services/ocaml-oxcaml/bin ./bin
COPY services/ocaml-oxcaml/test ./test

RUN eval "$(opam env --switch ${OXCAML_SWITCH})" \
 && dune build --root . --profile release \
 && dune runtest --root . --profile release

FROM ${DEBIAN_RUNTIME_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    libgmp10 \
    libssl3 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/_build/default/bin/main.exe /usr/local/bin/stt-ocaml-oxcaml

ENV PORT=9000
EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/stt-ocaml-oxcaml"]
