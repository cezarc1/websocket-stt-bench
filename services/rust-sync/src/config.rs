//! Process configuration, read once from the environment at startup.
//!
//! Mirrors the env contract every gateway in this benchmark shares
//! (`PORT`, `INFERENCE_URL`, `CPU_PASSES`, `MODEL_DELAY_MS`,
//! `FLUSH_INTERVAL_MS`, `FLUSH_PHASE_JITTER_MS`). `WORKER_THREADS` and
//! `INFERENCE_HTTP_CLIENTS` are accepted for compose/Helm symmetry but
//! intentionally unused: this gateway is one OS thread per connection with
//! one keep-alive inference connection per thread, so neither knob applies.

use std::env;
use std::time::Duration;

pub const FRAME_BYTES: usize = 640;

pub const CPU_PASSES_HEADER: &str = "x-cpu-passes";

pub const REASON_NEED_START: &str = "first message must be start";
pub const REASON_TEXT_AFTER_START: &str = "expected binary PCM frames after start";
pub const REASON_BAD_FRAME_SIZE: &str = "expected 640 byte PCM frame";

const DEFAULT_PORT: u16 = 10000;
const DEFAULT_INFERENCE_URL: &str = "http://inference-server:9000";
const DEFAULT_CPU_PASSES: u32 = 4;
const DEFAULT_MODEL_DELAY_MS: u64 = 75;
const DEFAULT_FLUSH_INTERVAL_MS: u64 = 1000;
const DEFAULT_FLUSH_PHASE_JITTER_MS: u64 = 0;

/// Per-connection inference call budget. Matches the rust-axum reqwest
/// client (1 s connect, 2 s overall) so the comparison isolates the
/// runtime, not the timeout policy.
pub const INFERENCE_CONNECT_TIMEOUT: Duration = Duration::from_secs(1);
pub const INFERENCE_TIMEOUT: Duration = Duration::from_secs(2);

/// Explicit per-connection thread stack. The default 2 MiB stack would cap
/// the pod at ~1k connections under the 2 GiB limit; the work here is
/// shallow (read → buffer → POST → relay) so 256 KiB is ample headroom.
pub const STACK_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone)]
pub struct Config {
    pub port: u16,
    /// Fully-qualified inference endpoint, e.g. `http://host:9000/infer`.
    pub inference_url: String,
    pub cpu_passes: u32,
    pub cpu_passes_header: String,
    pub model_delay_ms: u64,
    pub flush_interval: Duration,
    pub flush_phase_jitter: Duration,
}

impl Config {
    pub fn from_env() -> Self {
        let inference_base =
            env::var("INFERENCE_URL").unwrap_or_else(|_| DEFAULT_INFERENCE_URL.to_owned());
        let cpu_passes = env_parsed("CPU_PASSES", DEFAULT_CPU_PASSES);
        Self {
            port: env_parsed("PORT", DEFAULT_PORT),
            inference_url: format!("{}/infer", inference_base.trim_end_matches('/')),
            cpu_passes,
            cpu_passes_header: cpu_passes.to_string(),
            model_delay_ms: env_parsed("MODEL_DELAY_MS", DEFAULT_MODEL_DELAY_MS),
            flush_interval: Duration::from_millis(
                env_parsed("FLUSH_INTERVAL_MS", DEFAULT_FLUSH_INTERVAL_MS).max(1),
            ),
            flush_phase_jitter: Duration::from_millis(env_parsed(
                "FLUSH_PHASE_JITTER_MS",
                DEFAULT_FLUSH_PHASE_JITTER_MS,
            )),
        }
    }
}

fn env_parsed<T: std::str::FromStr>(name: &str, default: T) -> T {
    env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}
