use std::time::Duration;

use serde::{Deserialize, Serialize};

pub const FRAME_INTERVAL: Duration = Duration::from_millis(20);
pub const FRAME_BYTES: usize = 640;
pub const SAMPLES_PER_FRAME: usize = 320;
pub const FLUSH_INTERVAL: Duration = Duration::from_millis(1000);

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum StartMessage {
    Start,
}

/// Tagged union of every server-to-client message. Discriminator is the
/// JSON `"type"` field.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ServerMessage {
    Partial(PartialMessage),
    Error(ErrorMessage),
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PartialMessage {
    pub oldest_frame_seq: u64,
    pub newest_frame_seq: u64,
    pub frames: u64,
    pub rms: f64,
    pub zero_crossings: u64,
    pub checksum: u32,
    pub samples: u64,
    pub transcript: String,
    pub audio_bytes: u64,
    pub cpu_passes: u32,
    pub model_delay_ms: u64,
    pub flush_lateness_ms: f64,
    pub inflight_model_jobs: u64,
}

impl PartialMessage {
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.oldest_frame_seq > 0,
            "oldest_frame_seq must be positive"
        );
        anyhow::ensure!(
            self.newest_frame_seq >= self.oldest_frame_seq,
            "newest_frame_seq must be >= oldest_frame_seq"
        );
        anyhow::ensure!(self.frames > 0, "frames must be positive");
        anyhow::ensure!(self.samples > 0, "samples must be positive");
        anyhow::ensure!(!self.transcript.is_empty(), "transcript must be non-empty");
        anyhow::ensure!(self.audio_bytes > 0, "audio_bytes must be positive");
        anyhow::ensure!(self.rms.is_finite(), "rms must be finite");
        anyhow::ensure!(
            self.flush_lateness_ms.is_finite() && self.flush_lateness_ms >= 0.0,
            "flush_lateness_ms must be finite and non-negative"
        );
        Ok(())
    }
}

/// Diagnostic frame the gateway emits when a flush batch can't be served.
/// The connection stays open; subsequent flushes resume normally.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ErrorMessage {
    pub stage: String,
    pub kind: String,
    pub message: String,
    pub oldest_frame_seq: u64,
    pub newest_frame_seq: u64,
    pub frames: u64,
    pub audio_bytes: u64,
    pub oldest_age_ms: f64,
    pub newest_age_ms: f64,
    pub flush_lateness_ms: f64,
    pub inference_elapsed_ms: Option<f64>,
    pub inflight_gateway_batches: u64,
    pub gateway_buffer_frames: u64,
    pub inference_status: Option<u16>,
    pub retryable: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct GoldenStub {
    pub frames: u64,
    pub samples: u64,
    pub checksum: u32,
    pub zero_crossings: u64,
    pub rms: f64,
    pub transcript: &'static str,
    pub audio_bytes: u64,
}

// `transcript` is derived deterministically from `checksum` by the inference
// server: TRANSCRIPT_POOL[checksum % 24]. For checksum 1_745_339_397 that lands
// at index 21 → "now". If the inference server's pool is reordered, this
// constant must be updated together.
pub const GOLDEN_ONE_FRAME: GoldenStub = GoldenStub {
    frames: 1,
    samples: 1280,
    checksum: 1_745_339_397,
    zero_crossings: 7,
    rms: 2425.5023191083533,
    transcript: "now",
    audio_bytes: FRAME_BYTES as u64,
};

pub fn frame_payload(session_id: usize, seq: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(FRAME_BYTES);
    let base = seq
        .wrapping_mul(SAMPLES_PER_FRAME as u64)
        .wrapping_add(session_id as u64);
    for offset in 0..SAMPLES_PER_FRAME {
        let value = ((base + offset as u64).wrapping_mul(17) % 20_000) as i32 - 10_000;
        out.extend_from_slice(&(value as i16).to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_is_one_pcm_frame() {
        let payload = frame_payload(7, 11);
        assert_eq!(payload.len(), FRAME_BYTES);
        assert_ne!(payload, frame_payload(7, 12));
    }

    #[test]
    fn start_serializes_to_contract_shape() {
        let serialized = serde_json::to_string(&StartMessage::Start).unwrap();
        assert_eq!(serialized, r#"{"type":"start"}"#);
    }

    #[test]
    fn partial_decodes_via_server_message_tag() {
        let json = r#"{
            "type":"partial","oldest_frame_seq":1,"newest_frame_seq":1,"frames":1,
            "rms":0.0,"zero_crossings":0,"checksum":0,"samples":1,
            "transcript":"now","audio_bytes":640,"cpu_passes":4,"model_delay_ms":75,
            "flush_lateness_ms":0.0,"inflight_model_jobs":0
        }"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap();
        assert!(matches!(msg, ServerMessage::Partial(_)));
    }

    #[test]
    fn error_decodes_via_server_message_tag() {
        let json = r#"{
            "type":"error","stage":"inference_request","kind":"timeout",
            "message":"timed out","oldest_frame_seq":1,"newest_frame_seq":1,
            "frames":1,"audio_bytes":640,"oldest_age_ms":0.0,"newest_age_ms":0.0,
            "flush_lateness_ms":0.0,"inference_elapsed_ms":5000.0,
            "inflight_gateway_batches":1,"gateway_buffer_frames":0,
            "inference_status":null,"retryable":true
        }"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap();
        assert!(matches!(msg, ServerMessage::Error(_)));
    }
}
