# Linux-only no-Async OxCaml gateway image. This deliberately stays separate
# from docker/ocaml-oxcaml.Dockerfile so the accepted Async implementation
# remains unchanged while the epoll experiment evolves.

ARG OPAM_BASE_IMAGE=ocaml/opam:debian-12-ocaml-5.2
ARG DEBIAN_RUNTIME_IMAGE=debian:12-slim
ARG OXCAML_SWITCH=5.2.0+ox
ARG OXCAML_REPO_COMMIT=main

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
    pkg-config \
    zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

USER opam
WORKDIR /home/opam

ENV OPAMJOBS=${OXCAML_BUILD_JOBS}

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

RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    eval "$(opam env --switch ${OXCAML_SWITCH})" \
 && opam install --yes --switch ${OXCAML_SWITCH} \
    dune \
    yojson \
    alcotest \
 && opam clean

WORKDIR /app
COPY services/ocaml-oxcaml-epoll/dune-project ./dune-project
COPY services/ocaml-oxcaml-epoll/stt_ocaml_oxcaml_epoll.opam ./stt_ocaml_oxcaml_epoll.opam
COPY services/ocaml-oxcaml-epoll/.ocamlformat ./.ocamlformat
COPY services/ocaml-oxcaml-epoll/lib ./lib
COPY services/ocaml-oxcaml-epoll/linux ./linux
COPY services/ocaml-oxcaml-epoll/bin ./bin
COPY services/ocaml-oxcaml-epoll/test ./test

RUN eval "$(opam env --switch ${OXCAML_SWITCH})" \
 && dune build --root . --profile release \
 && dune runtest --root . --profile release

FROM ${DEBIAN_RUNTIME_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    libgmp10 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/_build/default/bin/main.exe /usr/local/bin/stt-ocaml-oxcaml-epoll

ENV PORT=9200
EXPOSE 9200

ENTRYPOINT ["/usr/local/bin/stt-ocaml-oxcaml-epoll"]
