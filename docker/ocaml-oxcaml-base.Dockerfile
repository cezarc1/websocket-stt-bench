# Stable base image carrying the OxCaml switch + every opam dep the gateway
# needs. Slow on first build (~15-25 min: builds the modified OCaml compiler
# from source + installs the full Jane Street stack), then frozen as
# `stt-bench-oxcaml-base:5.2.0+ox` so iteration on the gateway source itself
# is ~30 s instead of a fresh 15+ min compile.
#
# Rebuild only when:
#   - bumping OXCAML_REPO_COMMIT (pin in versions.lock.toml)
#   - changing the opam dependency set
# Otherwise the gateway Dockerfile FROMs this image untouched.

ARG OPAM_BASE_IMAGE=ocaml/opam:debian-12-ocaml-5.2
ARG OXCAML_SWITCH=5.2.0+ox
ARG OXCAML_REPO_COMMIT=main

FROM ${OPAM_BASE_IMAGE}

ARG OXCAML_SWITCH
ARG OXCAML_REPO_COMMIT

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

RUN OX_REPO="git+https://github.com/oxcaml/opam-repository.git" \
 && if [ "${OXCAML_REPO_COMMIT}" != "main" ]; then \
      OX_REPO="${OX_REPO}#${OXCAML_REPO_COMMIT}"; \
    fi \
 && opam update --yes \
 && opam switch create ${OXCAML_SWITCH} \
      --repos "ox=${OX_REPO},default" \
      --yes \
 && opam clean

RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    eval "$(opam env --switch ${OXCAML_SWITCH})" \
 && opam install --yes --switch ${OXCAML_SWITCH} \
    dune \
    base \
    core \
    core_unix \
    async \
    parallel \
    yojson \
    ppx_jane \
    alcotest \
 && opam clean

ENV OXCAML_SWITCH=${OXCAML_SWITCH}
