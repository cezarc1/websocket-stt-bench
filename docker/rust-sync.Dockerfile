FROM rust:1.95.0-bookworm AS build

WORKDIR /app

COPY rust-toolchain.toml Cargo.toml Cargo.lock deny.toml ./
COPY services/inference-server/Cargo.toml services/inference-server/Cargo.toml
COPY services/rust-axum/Cargo.toml services/rust-axum/Cargo.toml
COPY services/rust-sync/Cargo.toml services/rust-sync/Cargo.toml
COPY loadgen/rust/Cargo.toml loadgen/rust/Cargo.toml
COPY services/inference-server/src services/inference-server/src
COPY services/rust-axum/src services/rust-axum/src
COPY services/rust-sync/src services/rust-sync/src
COPY loadgen/rust/src loadgen/rust/src
RUN cargo fetch --locked
RUN cargo build --locked --release -p stt-rust-sync

FROM debian:bookworm-20260421-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/target/release/stt-rust-sync /usr/local/bin/stt-rust-sync

ENV PORT=10000
# Many short-lived per-connection threads otherwise spawn one glibc malloc
# arena each; cap it so memory stays flat (the hot path reuses scratch
# buffers, so arena parallelism buys nothing here).
ENV MALLOC_ARENA_MAX=2
EXPOSE 10000
CMD ["stt-rust-sync"]
