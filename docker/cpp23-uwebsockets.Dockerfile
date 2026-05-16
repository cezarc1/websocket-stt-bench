# Hermetic-as-possible C++23 + uWebSockets gateway.
#
# Build stage: Ubuntu Noble with apt-installed JDK 21 (Bazel runs on JVM),
# bazelisk pinned to the version in `versions.lock.toml`. Bazel fetches its
# own Clang 21 toolchain via toolchains_llvm — no host clang required.
#
# Runtime stage: noble-slim. The binary links against the system libstdc++
# (libstdc++6 ships with noble-slim), so we don't need to copy any toolchain
# libraries across the stages.
ARG BUILD_IMAGE=ubuntu:noble
ARG RUNTIME_IMAGE=ubuntu:noble
ARG BAZELISK_VERSION=1.29.0
ARG BAZEL_BUILD_CONFIG=opt

FROM ${BUILD_IMAGE} AS build

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    g++ \
    git \
    libcurl4-openssl-dev \
    libstdc++-13-dev \
    libxml2 \
    openjdk-21-jre-headless \
    pkg-config \
    python3 \
    unzip \
    xz-utils \
    zlib1g-dev \
  && rm -rf /var/lib/apt/lists/*

ARG BAZELISK_VERSION
ARG BAZEL_BUILD_CONFIG
# Detect arch at run time rather than relying on TARGETARCH so a plain
# `docker build` on Apple Silicon (no buildx) still picks bazelisk-linux-arm64
# instead of the amd64 binary that won't load under Rosetta.
RUN arch="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')" \
  && curl -fsSL "https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/bazelisk-linux-${arch}" \
      -o /usr/local/bin/bazel \
  && chmod +x /usr/local/bin/bazel

WORKDIR /app/services/cpp23-uwebsockets

# Copy build inputs in dependency order so source edits don't bust the
# expensive bzlmod fetch + Clang toolchain download.
COPY services/cpp23-uwebsockets/.bazelversion ./
COPY services/cpp23-uwebsockets/.bazelrc ./
COPY services/cpp23-uwebsockets/MODULE.bazel ./
COPY services/cpp23-uwebsockets/MODULE.bazel.lock* ./
COPY services/cpp23-uwebsockets/BUILD.bazel ./
COPY services/cpp23-uwebsockets/third_party ./third_party

RUN bazel fetch //...

COPY services/cpp23-uwebsockets/src ./src
COPY services/cpp23-uwebsockets/tests ./tests
COPY services/cpp23-uwebsockets/.clang-format ./
COPY services/cpp23-uwebsockets/.clang-tidy ./

RUN bazel build --config="${BAZEL_BUILD_CONFIG}" //:stt-cpp23-uwebsockets \
  && cp bazel-bin/stt-cpp23-uwebsockets /usr/local/lib/stt-cpp23-uwebsockets \
  # Bazel runs as root in the container, so shut it down cleanly to release
  # any output_base lock before Docker tarball'ing the layer.
  && bazel shutdown

FROM ${RUNTIME_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libcurl4t64 libstdc++6 \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/lib/stt-cpp23-uwebsockets /usr/local/bin/stt-cpp23-uwebsockets

ENV PORT=1500
EXPOSE 1500
ENTRYPOINT ["/usr/local/bin/stt-cpp23-uwebsockets"]
