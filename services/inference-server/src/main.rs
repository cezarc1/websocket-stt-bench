//! STT inference server for the websocket-stt-bench harness.
//!
//! All three gateway implementations (Python/FastAPI, Elixir/Phoenix, Rust/Axum)
//! call this service over HTTP/2 (h2c, cleartext) instead of computing inline.
//! Centralizing the deterministic compute here:
//!
//! 1. Eliminates cross-runtime algorithm drift — one canonical FNV/RMS/ZC
//!    implementation, shared by construction.
//! 2. Reframes the gateway benchmarks around what production gateways actually
//!    do: buffer frames, hand off to a model service, forward results.
//! 3. Decouples gateway compute pressure from model latency simulation.
//!
//! The server is sized in Compose with `cpus: 8` so it has structural CPU
//! headroom over any single gateway profile (cpus: 1.0 / 4.0). Combined with
//! the compute being only ~30k integer ops per request, the server should
//! never become the bottleneck under the benchmark's intended load. If it
//! does, the partials' `inference_busy_us` field will surface it.

use std::{env, net::SocketAddr, sync::Arc, time::Duration};

use axum::{
    Router,
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
};
use rand::RngExt;
use rand_distr::{Distribution, LogNormal};
use serde::Serialize;
use tokio::{sync::Semaphore, task, time::sleep};
use tracing::{info, warn};
use tracing_subscriber::{EnvFilter, fmt};

const DEFAULT_CPU_PASSES: u32 = 4;
const DEFAULT_MODEL_DELAY_MS: f64 = 75.0;
const DEFAULT_JITTER_SIGMA: f64 = 0.15;
const DEFAULT_LONGTAIL_PROB: f64 = 0.01;
const DEFAULT_LONGTAIL_MULT: f64 = 3.0;
const DEFAULT_BATCH_WAIT_MAX_MS: f64 = 20.0;
const DEFAULT_MAX_CONCURRENT: usize = 64;
const CPU_PASSES_HEADER: &str = "x-cpu-passes";

const FNV_OFFSET: u32 = 2_166_136_261;
const FNV_PRIME: u32 = 16_777_619;

// Placeholder STT vocabulary. The transcript for any input is selected by
// indexing this pool with the final FNV checksum, so identical PCM in always
// yields the same word.
const TRANSCRIPT_POOL: &[&str] = &[
    "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "hello", "world", "yes", "no",
    "okay", "right", "left", "stop", "go", "wait", "ready", "done", "again", "now", "later",
    "never",
];

#[derive(Clone)]
struct ServerState {
    default_cpu_passes: u32,
    // Median compute time (log-normal location parameter is ln(this)).
    model_delay_ms: f64,
    // Log-normal sigma. ~0.15 gives ~1.4× spread between p50 and p99.
    jitter_sigma: f64,
    // Probability that a request hits the long tail (CUDA recompile, GC, etc.).
    longtail_prob: f64,
    // Multiplier applied to the sampled latency on a long-tail event.
    longtail_mult: f64,
    // Triton-style batch window: each request waits a uniform-random share
    // of this duration to simulate batch-formation queueing.
    batch_wait_max_ms: f64,
    // Max concurrent inference requests; beyond this, requests queue. Models
    // a single GPU's stream cap.
    concurrency_sem: Arc<Semaphore>,
    max_concurrent: usize,
}

#[derive(Serialize)]
struct InferResponse {
    rms: f64,
    zero_crossings: u64,
    checksum: u32,
    samples: u64,
    transcript: &'static str,
    audio_bytes: u64,
}

#[derive(Debug)]
struct StubResult {
    rms: f64,
    zero_crossings: u64,
    checksum: u32,
    samples: u64,
    transcript: &'static str,
    audio_bytes: u64,
}

fn main() {
    let workers = resolve_worker_threads();
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        // compute_stub runs via spawn_blocking; default pool is 512. Raise
        // headroom so the inference server is never the bottleneck under
        // benchmark load — at 500 sessions ~150 blocking tasks are in flight,
        // 8192 leaves room for 50× scale-up before queueing.
        .max_blocking_threads(8192)
        .enable_all()
        .build()
        .expect("build tokio runtime")
        .block_on(async_main(workers));
}

async fn async_main(workers: usize) {
    fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .init();

    let max_concurrent = env_parsed::<usize>("MODEL_MAX_CONCURRENT", DEFAULT_MAX_CONCURRENT).max(1);
    let state = ServerState {
        default_cpu_passes: env_parsed::<u32>("CPU_PASSES", DEFAULT_CPU_PASSES),
        model_delay_ms: env_parsed::<f64>("MODEL_DELAY_MS", DEFAULT_MODEL_DELAY_MS),
        jitter_sigma: env_parsed::<f64>("MODEL_JITTER_SIGMA", DEFAULT_JITTER_SIGMA),
        longtail_prob: env_parsed::<f64>("MODEL_LONGTAIL_PROB", DEFAULT_LONGTAIL_PROB),
        longtail_mult: env_parsed::<f64>("MODEL_LONGTAIL_MULT", DEFAULT_LONGTAIL_MULT),
        batch_wait_max_ms: env_parsed::<f64>("MODEL_BATCH_WAIT_MAX_MS", DEFAULT_BATCH_WAIT_MAX_MS),
        concurrency_sem: Arc::new(Semaphore::new(max_concurrent)),
        max_concurrent,
    };

    info!(
        runtime = "stt-inference-server",
        rust = env!("CARGO_PKG_RUST_VERSION"),
        worker_threads = workers,
        default_cpu_passes = state.default_cpu_passes,
        model_delay_ms = state.model_delay_ms,
        jitter_sigma = state.jitter_sigma,
        longtail_prob = state.longtail_prob,
        longtail_mult = state.longtail_mult,
        batch_wait_max_ms = state.batch_wait_max_ms,
        max_concurrent = state.max_concurrent,
        "runtime_versions"
    );

    let app = Router::new()
        .route("/health", get(health))
        .route("/infer", post(infer))
        .with_state(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], env_parsed::<u16>("PORT", 9000)));
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind listener");

    info!(%addr, "listening");
    axum::serve(listener, app).await.expect("serve axum");
}

async fn health() -> &'static str {
    "ok"
}

async fn infer(
    State(state): State<ServerState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, (StatusCode, &'static str)> {
    if !body.len().is_multiple_of(2) {
        return Err((
            StatusCode::BAD_REQUEST,
            "body length must be even (i16 PCM)",
        ));
    }

    let cpu_passes = headers
        .get(CPU_PASSES_HEADER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(state.default_cpu_passes);

    // Acquire a "GPU stream" slot; queues if the simulated GPU is at max
    // concurrency. This is what makes p99 spike at saturation.
    let _permit = state
        .concurrency_sem
        .acquire()
        .await
        .map_err(|_| (StatusCode::SERVICE_UNAVAILABLE, "concurrency sem closed"))?;

    let result = task::spawn_blocking(move || compute_stub(&body, cpu_passes))
        .await
        .map_err(|error| {
            warn!(%error, "compute task panicked");
            (StatusCode::INTERNAL_SERVER_ERROR, "compute failed")
        })?;

    sleep(sample_latency(&state)).await;

    let response = InferResponse {
        rms: result.rms,
        zero_crossings: result.zero_crossings,
        checksum: result.checksum,
        samples: result.samples,
        transcript: result.transcript,
        audio_bytes: result.audio_bytes,
    };

    Ok(axum::Json(response))
}

/// Sample a per-request "GPU latency" from a model that combines:
/// - `batch_wait`: uniform 0..max — Triton-style batch-formation queueing.
/// - `compute`: log-normal around `model_delay_ms` — real GPU compute jitter.
/// - `longtail`: small probability of a multiplicative spike — CUDA recompile,
///   memory defrag, host-side stall.
fn sample_latency(state: &ServerState) -> Duration {
    let mut rng = rand::rng();

    let batch_wait = if state.batch_wait_max_ms > 0.0 {
        rng.random_range(0.0..state.batch_wait_max_ms)
    } else {
        0.0
    };

    let mut compute = if state.jitter_sigma > 0.0 {
        let dist = LogNormal::new(state.model_delay_ms.ln(), state.jitter_sigma)
            .expect("valid log-normal parameters");
        dist.sample(&mut rng)
    } else {
        state.model_delay_ms
    };

    if state.longtail_prob > 0.0 && rng.random_bool(state.longtail_prob.clamp(0.0, 1.0)) {
        compute *= state.longtail_mult;
    }

    let total_ms = (batch_wait + compute).max(0.0);
    Duration::from_secs_f64(total_ms / 1000.0)
}

fn compute_stub(payload: &[u8], passes: u32) -> StubResult {
    let mut checksum = FNV_OFFSET;
    let mut zero_crossings = 0_u64;
    let mut sum_squares = 0_i128;
    let mut sample_count = 0_u64;
    let mut previous = 0_i16;

    for pass_index in 0..passes {
        for chunk in payload.chunks_exact(2) {
            let sample = i16::from_le_bytes([chunk[0], chunk[1]]);
            if sample_count > 0 && ((sample < 0 && previous >= 0) || (previous < 0 && sample >= 0))
            {
                zero_crossings += 1;
            }
            let adjusted = (sample as i32 + 32_768 + pass_index as i32) as u32;
            checksum ^= adjusted & 0xFFFF;
            checksum = checksum.wrapping_mul(FNV_PRIME);
            sum_squares += i128::from(sample) * i128::from(sample);
            sample_count += 1;
            previous = sample;
        }
    }

    let rms = if sample_count == 0 {
        0.0
    } else {
        ((sum_squares as f64) / (sample_count as f64)).sqrt()
    };

    let transcript = TRANSCRIPT_POOL[(checksum as usize) % TRANSCRIPT_POOL.len()];

    StubResult {
        rms,
        zero_crossings,
        checksum,
        samples: sample_count,
        transcript,
        audio_bytes: payload.len() as u64,
    }
}

fn resolve_worker_threads() -> usize {
    let configured = env_parsed::<usize>("WORKER_THREADS", 0);
    if configured > 0 {
        return configured;
    }
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
}

fn env_parsed<T: std::str::FromStr>(name: &str, default: T) -> T {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<T>().ok())
        .unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_is_deterministic() {
        let payload: Vec<u8> = [0_i16, 100, -100, 200]
            .into_iter()
            .flat_map(i16::to_le_bytes)
            .collect();
        let left = compute_stub(&payload, 4);
        let right = compute_stub(&payload, 4);

        assert_eq!(left.checksum, right.checksum);
        assert_eq!(left.zero_crossings, right.zero_crossings);
        assert_eq!(left.samples, 16);
        assert_eq!(left.transcript, right.transcript);
        assert_eq!(left.audio_bytes, payload.len() as u64);
        assert!(TRANSCRIPT_POOL.contains(&left.transcript));
    }
}
