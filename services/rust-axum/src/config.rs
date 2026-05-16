use std::{env, time::Duration};

pub(crate) const FRAME_BYTES: usize = 640;
pub(crate) const TYPICAL_BATCH: usize = 50;
pub(crate) const DEFAULT_FLUSH_INTERVAL_MS: u64 = 1000;

// Per-connection limits. The semaphore makes the back-pressure invariant
// from CLAUDE.md explicit at the call site; the channel depth is sized for
// the at-most-one-inflight regime (1 in flight + 1 buffered = 2; 4 leaves
// headroom without inviting unbounded queueing).
pub(crate) const MAX_INFLIGHT_INFERENCES: usize = 1;
pub(crate) const PARTIAL_CHANNEL_DEPTH: usize = 4;
pub(crate) const DEFAULT_CPU_PASSES: u32 = 4;
pub(crate) const DEFAULT_MODEL_DELAY: Duration = Duration::from_millis(75);
pub(crate) const DEFAULT_FLUSH_PHASE_JITTER_MS: u64 = 0;
pub(crate) const DEFAULT_INFERENCE_HTTP_CLIENTS: usize = 512;
pub(crate) const DEFAULT_INFERENCE_URL: &str = "http://inference-server:9000";
pub(crate) const CPU_PASSES_HEADER: &str = "x-cpu-passes";
pub(crate) const CLOSE_PROTOCOL_ERROR: u16 = 1002;
pub(crate) const CLOSE_UNSUPPORTED_DATA: u16 = 1003;
pub(crate) const REASON_NEED_START: &str = "first message must be start";
pub(crate) const REASON_TEXT_AFTER_START: &str = "expected binary PCM frames after start";
pub(crate) const REASON_BAD_FRAME_SIZE: &str = "expected 640 byte PCM frame";

// Keep these in sync with the pinned versions in workspace Cargo.toml.
pub(crate) const AXUM_VERSION: &str = "0.8.9";
pub(crate) const TOKIO_VERSION: &str = "1.52.1";
pub(crate) const REQWEST_VERSION: &str = "0.12.27";

pub(crate) fn env_parsed<T: std::str::FromStr>(name: &str, default: T) -> T {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<T>().ok())
        .unwrap_or(default)
}

pub(crate) fn resolve_worker_threads() -> usize {
    let configured = env_parsed::<usize>("WORKER_THREADS", 0);
    if configured > 0 {
        return configured;
    }
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
}
