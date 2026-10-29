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

// Stub output for `frame_payload(0, 1)` at 4 passes. Cross-checked against the
// Python reference impl (`services/python-fastapi/tests/test_stub_parity.py::
// test_loadgen_frame_payload_goldens`). `transcript` is derived from
// `checksum` by the shared stub: TRANSCRIPT_POOL[checksum % 24]; for checksum
// 763_539_697 that is index 1 → "quick". If the pool is reordered, this
// constant must be updated together.
pub const GOLDEN_ONE_FRAME: GoldenStub = GoldenStub {
    frames: 1,
    samples: 1280,
    checksum: 763_539_697,
    zero_crossings: 7,
    rms: 8_323.765_219_801_373,
    transcript: "quick",
    audio_bytes: FRAME_BYTES as u64,
};

/// splitmix64 finalizer (Steele et al.): a cheap 64-bit bijection with full
/// avalanche, so every output bit depends non-linearly on every input bit.
const fn mix64(mut z: u64) -> u64 {
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

const SPLITMIX_GAMMA: u64 = 0x9E37_79B9_7F4A_7C15;
/// Sawtooth carrier: 17 units/sample over a 20 000-unit period (~1176
/// samples), centred on zero — the same slope and range as the original
/// generator, so `compute_stub`'s zero-crossing branch stays predictable and
/// the inference server's per-batch CPU cost is unchanged.
const SAW_PERIOD: i32 = 20_000;
const SAW_STEP: i32 = 17;
/// Noise is uniform in `-NOISE_HALF..NOISE_HALF`.
const NOISE_HALF: i32 = 256;

/// Deterministic PCM for frame `seq` of `session_id`.
///
/// `seed = mix64(mix64(session_id) ^ seq)` picks the sawtooth's starting
/// phase and seeds a splitmix64 stream; each 64-bit output supplies 9-bit
/// noise for 4 consecutive samples. Samples stay within ±10 256 and cross
/// zero where the carrier does (with a little noise jitter there).
///
/// Content is a non-linear function of (session, seq), so distinct pairs do
/// not share content: a stale result from N frames back, frame q replaced by
/// q-k, or session s answered with session s+k all change the checksum. (The
/// previous generator was linear in seq: it repeated every 125 frames and
/// frame (s+160, q) equalled (s, q+63).)
///
/// Python port for cross-checking goldens:
/// `services/python-fastapi/tests/golden.py::loadgen_frame_payload`.
pub fn frame_payload(session_id: usize, seq: u64) -> Vec<u8> {
    const _: () = assert!(FRAME_BYTES == SAMPLES_PER_FRAME * 2 && FRAME_BYTES.is_multiple_of(8));
    let mut out = [0_u8; FRAME_BYTES];
    let mut state = mix64(mix64(session_id as u64) ^ seq);
    let mut carrier = (state % SAW_PERIOD as u64) as i32;
    for chunk in out.chunks_exact_mut(8) {
        state = state.wrapping_add(SPLITMIX_GAMMA);
        let noise = mix64(state);
        for (lane, sample) in chunk.chunks_exact_mut(2).enumerate() {
            let jitter = ((noise >> (16 * lane)) & 0x1FF) as i32 - NOISE_HALF;
            let value = carrier - SAW_PERIOD / 2 + jitter;
            sample.copy_from_slice(&(value as i16).to_le_bytes());
            carrier += SAW_STEP;
            if carrier >= SAW_PERIOD {
                carrier -= SAW_PERIOD;
            }
        }
    }
    out.to_vec()
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

    /// The old linear generator repeated every 125 frames and made frame
    /// (s+160, q) identical to (s, q+63). Every (session, seq) pair in a
    /// realistic window must now be unique.
    #[test]
    fn payloads_do_not_alias_across_seq_or_session() {
        let mut seen = std::collections::HashSet::new();
        for session in [0_usize, 1, 2, 160, 161, 320, 7_919] {
            for seq in 1..=1_000_u64 {
                assert!(
                    seen.insert(frame_payload(session, seq)),
                    "frame_payload({session}, {seq}) repeats an earlier frame"
                );
            }
        }
    }

    #[test]
    fn payload_stays_in_range_and_crosses_zero() {
        let samples: Vec<i16> = (1..=50)
            .flat_map(|seq| frame_payload(3, seq))
            .collect::<Vec<u8>>()
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]))
            .collect();
        assert!(samples.iter().all(|s| s.unsigned_abs() <= 10_256));
        assert!(samples.iter().any(|&s| s > 9_000));
        assert!(samples.iter().any(|&s| s < -9_000));
        let crossings = samples
            .windows(2)
            .filter(|w| (w[0] < 0) != (w[1] < 0))
            .count();
        // Low-frequency carrier: crossings are sparse (branch-predictable in
        // `compute_stub`) but present in every flush-sized batch.
        assert!((10..=2_000).contains(&crossings), "crossings {crossings}");
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
