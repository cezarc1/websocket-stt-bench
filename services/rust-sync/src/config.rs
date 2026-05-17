//! Process configuration, read once from the environment at startup.
//!
//! Mirrors the env contract every gateway in this benchmark shares
//! (`PORT`, `INFERENCE_URL`, `CPU_PASSES`, `MODEL_DELAY_MS`,
//! `FLUSH_INTERVAL_MS`, `FLUSH_PHASE_JITTER_MS`). `WORKER_THREADS` /
//! `INFERENCE_HTTP_CLIENTS` are accepted for compose/Helm symmetry but
//! unused: this gateway is a single epoll event loop, not threads or a
//! client pool.

use std::env;
use std::time::Duration;

pub const FRAME_BYTES: usize = 640;

pub const REASON_NEED_START: &str = "first message must be start";
pub const REASON_TEXT_AFTER_START: &str = "expected binary PCM frames after start";
pub const REASON_BAD_FRAME_SIZE: &str = "expected 640 byte PCM frame";

/// Per-request inference budget, matching rust-axum's reqwest client so
/// the comparison isolates the runtime, not the timeout policy.
pub const INFERENCE_TIMEOUT: Duration = Duration::from_secs(2);

/// Listen backlog. The loadgen opens every session within a ~1 s spread,
/// so the default queue overflows and the kernel drops SYNs (client-side
/// connect timeouts) before steady state. A deep queue absorbs the burst.
pub const LISTEN_BACKLOG: i32 = 8192;

const DEFAULT_PORT: u16 = 10000;
const DEFAULT_INFERENCE_URL: &str = "http://inference-server:9000";
/// Shared inference connection pool size. Matches rust-axum's default so
/// the comparison isolates the runtime, not the transport fan-out; one
/// pooled HTTP/1.1 socket per *in-flight* request rather than one per
/// gateway connection keeps the single event loop's fd count bounded.
// HTTP/1.1 has no request multiplexing, so a pooled socket serves one
// request at a time: steady-state slots-in-use ≈ sessions × request-RT.
// A too-small pool exhausts under load (skipped flushes → oldest-frame
// latency blows up). 2048 covers the measured envelope while still being
// far below one-socket-per-session's fd fan-out.
const DEFAULT_INFERENCE_CLIENTS: usize = 2048;
const DEFAULT_CPU_PASSES: u32 = 4;
const DEFAULT_MODEL_DELAY_MS: u64 = 75;
const DEFAULT_FLUSH_INTERVAL_MS: u64 = 1000;
const DEFAULT_FLUSH_PHASE_JITTER_MS: u64 = 0;

#[derive(Debug, Clone)]
pub struct Config {
    pub port: u16,
    /// `host:port` of the inference server (for the non-blocking TCP
    /// connect and DNS re-resolution on redial).
    pub inference_host: String,
    pub inference_port: u16,
    /// Request path, e.g. `/infer`.
    pub inference_path: String,
    pub inference_clients: usize,
    pub cpu_passes: u32,
    pub model_delay_ms: u64,
    pub flush_interval: Duration,
    pub flush_phase_jitter: Duration,
}

impl Config {
    pub fn from_env() -> Self {
        let url = env::var("INFERENCE_URL").unwrap_or_else(|_| DEFAULT_INFERENCE_URL.to_owned());
        let (inference_host, inference_port) = parse_authority(&url);
        let cpu_passes = env_parsed("CPU_PASSES", DEFAULT_CPU_PASSES);
        Self {
            port: env_parsed("PORT", DEFAULT_PORT),
            inference_host,
            inference_port,
            inference_path: "/infer".to_owned(),
            inference_clients: env_parsed("INFERENCE_HTTP_CLIENTS", DEFAULT_INFERENCE_CLIENTS)
                .max(1),
            cpu_passes,
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

/// Extract `(host, port)` from an `http://host:port[/...]` URL. Only the
/// cleartext-HTTP shape this benchmark uses is supported.
fn parse_authority(url: &str) -> (String, u16) {
    let rest = url.strip_prefix("http://").unwrap_or(url);
    let authority = rest.split('/').next().unwrap_or(rest);
    match authority.rsplit_once(':') {
        Some((host, port)) => (host.to_owned(), port.parse().unwrap_or(80)),
        None => (authority.to_owned(), 80),
    }
}

fn env_parsed<T: std::str::FromStr>(name: &str, default: T) -> T {
    env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use super::parse_authority;

    #[test]
    fn parses_url_authority() {
        assert_eq!(
            parse_authority("http://inference-server:9000"),
            ("inference-server".to_owned(), 9000)
        );
        assert_eq!(
            parse_authority("http://inference-server:9000/infer"),
            ("inference-server".to_owned(), 9000)
        );
        assert_eq!(parse_authority("http://host"), ("host".to_owned(), 80));
    }
}
