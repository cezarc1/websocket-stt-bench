//! Canonical synchronous Rust STT gateway: one OS thread per WebSocket
//! connection, blocking I/O, no async runtime. See `session.rs` for the
//! per-connection loop and the structural one-inflight invariant.

mod config;
mod http;
mod inference;
mod protocol;
mod session;

use std::net::TcpListener;
use std::sync::Arc;
use std::thread;

use crate::config::{Config, STACK_BYTES};

fn main() {
    let config = Arc::new(Config::from_env());
    let listener = TcpListener::bind(("0.0.0.0", config.port)).expect("bind listener");
    eprintln!(
        "{{\"runtime\":\"rust-sync\",\"rust\":\"{}\",\"port\":{},\"inference_url\":\"{}\",\"flush_interval_ms\":{}}}",
        env!("CARGO_PKG_RUST_VERSION"),
        config.port,
        config.inference_url,
        config.flush_interval.as_millis(),
    );

    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let config = Arc::clone(&config);
        let spawned = thread::Builder::new()
            .stack_size(STACK_BYTES)
            .spawn(move || session::serve(stream, &config));
        // Failing to spawn (OS thread/pid limit) drops the connection —
        // back-pressure at the only place a thread-per-connection model
        // can express it.
        drop(spawned);
    }
}
