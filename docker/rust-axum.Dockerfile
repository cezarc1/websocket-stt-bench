FROM rust:1.95.0-bookworm AS build

WORKDIR /app

COPY rust-toolchain.toml Cargo.toml Cargo.lock deny.toml ./
COPY services/inference-server/Cargo.toml services/inference-server/Cargo.toml
COPY services/rust-axum/Cargo.toml services/rust-axum/Cargo.toml
COPY loadgen/rust/Cargo.toml loadgen/rust/Cargo.toml
COPY services/inference-server/src services/inference-server/src
COPY services/rust-axum/src services/rust-axum/src
COPY loadgen/rust/src loadgen/rust/src
RUN cargo fetch --locked
RUN cargo build --locked --release -p stt-rust-axum

FROM debian:bookworm-20260421-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/target/release/stt-rust-axum /usr/local/bin/stt-rust-axum

ENV PORT=3000
EXPOSE 3000
CMD ["stt-rust-axum"]
