# Self-contained OxCaml gateway image. Builds the OxCaml 5.2.0+ox switch
# from source + the opam dep closure, then the gateway, then a slim
# runtime stage. The cold build is ~20-30 min (compiling the modified
# OCaml compiler); CI caches the opam download cache across runs.
#
# Local iteration does NOT use this Dockerfile — it uses the opam switch
# directly (`opam exec --switch 5.2.0+ox -- dune build` in
# services/ocaml-oxcaml). This file is the reproducible CI/cluster path.

ARG OPAM_BASE_IMAGE=ocaml/opam:debian-12-ocaml-5.2
ARG DEBIAN_RUNTIME_IMAGE=debian:12-slim
ARG OXCAML_SWITCH=5.2.0+ox
ARG OXCAML_REPO_COMMIT=main

# ---- Stage 1: OxCaml switch + deps + gateway build ----------------------
FROM ${OPAM_BASE_IMAGE} AS build

ARG OXCAML_SWITCH
ARG OXCAML_REPO_COMMIT
ARG OXCAML_BUILD_JOBS=1

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    autoconf \
    build-essential \
    git \
    ca-certificates \
    libgmp-dev \
    libssl-dev \
    libffi-dev \
    pkg-config \
    zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

USER opam
WORKDIR /home/opam

# Docker Desktop amd64 emulation can fail OxCaml's nested make jobserver
# path with "write jobserver: Bad file descriptor"; keep compiler image
# builds single-job. This is build-only and does not affect runtime.
ENV OPAMJOBS=${OXCAML_BUILD_JOBS}

# Create the OxCaml switch with the ox repo prepended to the resolver
# search path (matches https://oxcaml.org/get-oxcaml/). Adding the ox
# repo to the BASE switch first would inherit the stock-5.2 invariant
# and fail with "no matching version".
RUN OX_REPO="git+https://github.com/oxcaml/opam-repository.git" \
 && if [ "${OXCAML_REPO_COMMIT}" != "main" ]; then \
      OX_REPO="${OX_REPO}#${OXCAML_REPO_COMMIT}"; \
    fi \
 && opam update --yes \
 && opam switch create ${OXCAML_SWITCH} \
      --repos "ox=${OX_REPO},default" \
      --yes \
 && opam clean

USER root
RUN mkdir -p /home/opam/.cache/dune \
 && chown -R opam:opam /home/opam/.cache

USER opam
ENV DUNE_CACHE_ROOT=/home/opam/.cache/dune

# Dep closure as its own cached layer so source-only rebuilds skip it.
# We don't pin versions: the OxCaml repo invariant pins many of these to
# +ox/~preview variants whose numbers diverge from upstream; opam
# resolves the blessed flavor automatically.
RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    eval "$(opam env --switch ${OXCAML_SWITCH})" \
 && opam install --yes --switch ${OXCAML_SWITCH} \
    dune \
    base \
    core \
    core_unix \
    async \
    chrome-trace \
    yojson \
    ppx_jane \
    alcotest \
 && opam clean

# Gateway source last so iterating .ml files doesn't bust the dep layer.
WORKDIR /app
COPY services/ocaml-oxcaml/dune-project ./dune-project
COPY services/ocaml-oxcaml/stt_ocaml_oxcaml.opam ./stt_ocaml_oxcaml.opam
COPY services/ocaml-oxcaml/.ocamlformat ./.ocamlformat
COPY services/ocaml-oxcaml/lib ./lib
COPY services/ocaml-oxcaml/bin ./bin
COPY services/ocaml-oxcaml/test ./test

RUN eval "$(opam env --switch ${OXCAML_SWITCH})" \
 && dune build --root . --profile release \
 && dune runtest --root . --profile release

# ---- Stage 2: slim runtime ----------------------------------------------
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
