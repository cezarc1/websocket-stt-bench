use std::time::{Duration, Instant};

use bytes::Bytes;
use serde::{Deserialize, Serialize};

pub(crate) const PARTIAL_TYPE: &str = "partial";
pub(crate) const ERROR_TYPE: &str = "error";

#[derive(Debug)]
pub(crate) struct Frame {
    pub(crate) seq: u64,
    pub(crate) payload: Bytes,
    pub(crate) received_at: Instant,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct PartialContext {
    pub(crate) oldest_frame_seq: u64,
    pub(crate) newest_frame_seq: u64,
    pub(crate) frames: usize,
    pub(crate) flush_lateness_ms: f64,
}

#[derive(Deserialize)]
pub(crate) struct InferResponse {
    pub(crate) rms: f64,
    pub(crate) zero_crossings: u64,
    pub(crate) checksum: u32,
    pub(crate) samples: u64,
    pub(crate) transcript: String,
    pub(crate) audio_bytes: u64,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum ClientMessage {
    Start,
}

#[derive(Debug, Serialize)]
pub(crate) struct PartialMessage {
    pub(crate) r#type: &'static str,
    pub(crate) oldest_frame_seq: u64,
    pub(crate) newest_frame_seq: u64,
    pub(crate) frames: usize,
    pub(crate) rms: f64,
    pub(crate) zero_crossings: u64,
    pub(crate) checksum: u32,
    pub(crate) samples: u64,
    pub(crate) transcript: String,
    pub(crate) audio_bytes: u64,
    pub(crate) cpu_passes: u32,
    pub(crate) model_delay_ms: u64,
    pub(crate) flush_lateness_ms: f64,
    pub(crate) inflight_model_jobs: usize,
}

impl PartialMessage {
    pub(crate) fn new(
        infer: InferResponse,
        context: PartialContext,
        cpu_passes: u32,
        model_delay: Duration,
    ) -> Self {
        Self {
            r#type: PARTIAL_TYPE,
            oldest_frame_seq: context.oldest_frame_seq,
            newest_frame_seq: context.newest_frame_seq,
            frames: context.frames,
            rms: infer.rms,
            zero_crossings: infer.zero_crossings,
            checksum: infer.checksum,
            samples: infer.samples,
            transcript: infer.transcript,
            audio_bytes: infer.audio_bytes,
            cpu_passes,
            model_delay_ms: model_delay.as_millis() as u64,
            flush_lateness_ms: context.flush_lateness_ms,
            inflight_model_jobs: 0,
        }
    }
}

// Variants other than InferenceRequest/InferenceResponseParse are forward-
// looking — current code only emits errors at those two stages — but they're
// kept in the wire-shared enum so the schema is stable across the three
// runtimes.
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ErrorStage {
    WebsocketReceive,
    BatchFlush,
    InferenceRequest,
    InferenceResponseParse,
    WebsocketSend,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ErrorKind {
    Timeout,
    PoolTimeout,
    // serde's snake_case rename strips the underscore before digits
    // (`Http5xx` → `"http5xx"`); we explicitly rename to match the
    // wire-shared spelling that Python and Elixir use.
    #[serde(rename = "http_5xx")]
    Http5xx,
    #[serde(rename = "http_429")]
    Http429,
    ConnectionReset,
    ParseError,
    SendError,
}

#[derive(Debug, Serialize)]
pub(crate) struct ErrorMessage {
    pub(crate) r#type: &'static str,
    pub(crate) stage: ErrorStage,
    pub(crate) kind: ErrorKind,
    pub(crate) message: String,
    // Batch identity
    pub(crate) oldest_frame_seq: u64,
    pub(crate) newest_frame_seq: u64,
    pub(crate) frames: usize,
    pub(crate) audio_bytes: u64,
    // Timing (ms)
    pub(crate) oldest_age_ms: f64,
    pub(crate) newest_age_ms: f64,
    pub(crate) flush_lateness_ms: f64,
    pub(crate) inference_elapsed_ms: Option<f64>,
    // Gateway pressure
    pub(crate) inflight_gateway_batches: usize,
    pub(crate) gateway_buffer_frames: usize,
    // Inference response info (None if no response was received)
    pub(crate) inference_status: Option<u16>,
    pub(crate) retryable: bool,
}
