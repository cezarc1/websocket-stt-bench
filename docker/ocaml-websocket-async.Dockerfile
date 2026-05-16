# Stock OCaml Async gateway image. Uses the upstream OCaml opam image while
# keeping the hot transport path raw enough for a best-effort runtime result.

ARG OPAM_BASE_IMAGE=ocaml/opam:debian-12-ocaml-5.4
ARG DEBIAN_RUNTIME_IMAGE=debian:12-slim

# ---- Stage 1: deps + gateway build --------------------------------------
FROM ${OPAM_BASE_IMAGE} AS build

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    libgmp-dev \
    pkg-config \
 && rm -rf /var/lib/apt/lists/*

USER opam
WORKDIR /app

# Dep closure as its own cached layer so source-only rebuilds skip it.
RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    opam update --yes \
 && opam install --yes \
    ocamlformat.0.29.0 \
    dune \
    core \
    core_unix \
    async \
    yojson \
    ppx_jane \
    alcotest \
 && opam clean

COPY services/ocaml-websocket-async/dune-project ./dune-project
COPY services/ocaml-websocket-async/.ocamlformat ./.ocamlformat
COPY services/ocaml-websocket-async/lib ./lib
COPY services/ocaml-websocket-async/bin ./bin
COPY services/ocaml-websocket-async/test ./test

RUN eval "$(opam env)" \
 && dune build --root . --profile release \
 && dune runtest --root . --profile release

# ---- Stage 2: slim runtime ----------------------------------------------
FROM ${DEBIAN_RUNTIME_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    libgmp10 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/_build/default/bin/main.exe /usr/local/bin/stt-ocaml-websocket-async

ENV PORT=9100
EXPOSE 9100

ENTRYPOINT ["/usr/local/bin/stt-ocaml-websocket-async"]
