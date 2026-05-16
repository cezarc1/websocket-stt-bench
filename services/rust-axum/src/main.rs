use std::{
    env,
    net::SocketAddr,
    sync::{Arc, atomic::AtomicUsize},
    time::Duration,
};

use axum::{Json, Router, http::HeaderValue, routing::get};
use serde::Serialize;
use tokio::net::TcpListener;
use tracing::info;
use tracing_subscriber::{EnvFilter, fmt};

mod config;
mod inference;
mod protocol;
mod session;
mod state;

use crate::config::{
    AXUM_VERSION, DEFAULT_CPU_PASSES, DEFAULT_FLUSH_INTERVAL_MS, DEFAULT_FLUSH_PHASE_JITTER_MS,
    DEFAULT_INFERENCE_HTTP_CLIENTS, DEFAULT_INFERENCE_URL, DEFAULT_MODEL_DELAY, REQWEST_VERSION,
    TOKIO_VERSION, env_parsed, resolve_worker_threads,
};
use crate::session::ws_handler;
use crate::state::AppContext;

fn main() {
    let workers = resolve_worker_threads();
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        .enable_all()
        .build()
        .expect("build tokio runtime")
        .block_on(async_main(workers));
}

async fn async_main(workers: usize) {
    fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .init();
    let inference_url =
        env::var("INFERENCE_URL").unwrap_or_else(|_| DEFAULT_INFERENCE_URL.to_owned());
    let cpu_passes = env_parsed::<u32>("CPU_PASSES", DEFAULT_CPU_PASSES);
    let model_delay = Duration::from_millis(env_parsed::<u64>(
        "MODEL_DELAY_MS",
        DEFAULT_MODEL_DELAY.as_millis() as u64,
    ));
    let flush_interval = Duration::from_millis(
        env_parsed::<u64>("FLUSH_INTERVAL_MS", DEFAULT_FLUSH_INTERVAL_MS).max(1),
    );
    let flush_phase_jitter = Duration::from_millis(env_parsed::<u64>(
        "FLUSH_PHASE_JITTER_MS",
        DEFAULT_FLUSH_PHASE_JITTER_MS,
    ));
    let inference_http_clients =
        env_parsed::<usize>("INFERENCE_HTTP_CLIENTS", DEFAULT_INFERENCE_HTTP_CLIENTS).max(1);
    let clients: Arc<[reqwest::Client]> = (0..inference_http_clients)
        .map(|_| build_inference_client())
        .collect::<Vec<_>>()
        .into();

    info!(
        runtime = "rust-axum",
        rust = env!("CARGO_PKG_RUST_VERSION"),
        axum = AXUM_VERSION,
        tokio = TOKIO_VERSION,
        reqwest = REQWEST_VERSION,
        worker_threads = workers,
        inference_http_clients,
        inference_url = %inference_url,
        flush_interval_ms = flush_interval.as_millis(),
        "runtime_versions"
    );
    let context = AppContext {
        clients,
        next_client: Arc::new(AtomicUsize::new(0)),
        inference_url: format!("{}/infer", inference_url.trim_end_matches('/')).into(),
        cpu_passes_header: HeaderValue::from(cpu_passes),
        cpu_passes,
        model_delay,
        flush_interval,
        flush_phase_jitter,
    };
    let app = Router::new()
        .route("/health", get(health))
        .route("/ws/stt", get(ws_handler))
        .with_state(context);
    let addr = SocketAddr::from(([0, 0, 0, 0], env_parsed::<u16>("PORT", 3000)));
    let listener = TcpListener::bind(addr).await.expect("bind listener");
    info!(%addr, "listening");
    axum::serve(listener, app).await.expect("serve axum");
}

fn build_inference_client() -> reqwest::Client {
    reqwest::Client::builder()
        .http2_prior_knowledge()
        .pool_idle_timeout(Duration::from_secs(60))
        .http2_keep_alive_interval(Duration::from_secs(15))
        .http2_keep_alive_while_idle(true)
        .connect_timeout(Duration::from_secs(1))
        .timeout(Duration::from_secs(2))
        .build()
        .expect("build reqwest client")
}

#[derive(Serialize)]
struct HealthResponse {
    ok: bool,
    runtime: &'static str,
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        ok: true,
        runtime: "rust-axum",
    })
}
