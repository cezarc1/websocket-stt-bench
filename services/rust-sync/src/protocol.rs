//! Wire types for the shared `/ws/stt` protocol.
//!
//! Implemented to the black-box contract (CLAUDE.md "Shared protocol
//! contract" + `loadgen/rust/src/protocol.rs`), not by copying another
//! gateway's internals. Both boundaries are strict: unknown fields are
//! rejected, mirroring serde `deny_unknown_fields` / Pydantic
//! `extra="forbid"` used by the other runtimes.

use serde::{Deserialize, Serialize};

/// First client message. Must parse as `{"type":"start"}`.
///
/// `deny_unknown_fields` is intentionally *not* set: serde silently
/// ignores it on internally-tagged enums, and the canonical contract type
/// (`loadgen/rust/src/protocol.rs::StartMessage`) is the same shape with
/// the same quirk. Matching the reference's leniency on extra fields is a
/// black-box-substitutability requirement, not an oversight — the
/// `invalid start` case the conformance harness exercises is non-JSON /
/// wrong-`type`, both of which still fail to parse here.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StartMessage {
    Start,
}

/// Inference server `/infer` response envelope.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InferResponse {
    pub rms: f64,
    pub zero_crossings: u64,
    pub checksum: u32,
    pub samples: u64,
    pub transcript: String,
    pub audio_bytes: u64,
}

/// Server → client success frame. Field set and `type` tag are fixed by
/// the contract; the loadgen computes latency curves from
/// `oldest_frame_seq`/`newest_frame_seq`/`flush_lateness_ms`.
#[derive(Debug, Serialize)]
pub struct PartialMessage {
    #[serde(rename = "type")]
    pub type_tag: &'static str,
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

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorStage {
    InferenceRequest,
    InferenceResponseParse,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    Timeout,
    // serde's snake_case strips the underscore before digits
    // (`Http5xx` → `"http5xx"`); rename to the wire spelling the other
    // runtimes use.
    #[serde(rename = "http_5xx")]
    Http5xx,
    #[serde(rename = "http_429")]
    Http429,
    ConnectionReset,
    ParseError,
}

/// Server → client diagnostic frame emitted when a flush batch can't be
/// served. The connection stays open; later flushes resume normally.
#[derive(Debug, Serialize)]
pub struct ErrorMessage {
    #[serde(rename = "type")]
    pub type_tag: &'static str,
    pub stage: ErrorStage,
    pub kind: ErrorKind,
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

pub const PARTIAL_TYPE: &str = "partial";
pub const ERROR_TYPE: &str = "error";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_accepts_exact_contract_shape() {
        assert!(serde_json::from_str::<StartMessage>(r#"{"type":"start"}"#).is_ok());
    }

    #[test]
    fn start_rejects_non_json_and_wrong_type() {
        // The two shapes the `invalid start` conformance case actually
        // exercises. Extra fields are accepted on purpose — see the
        // `StartMessage` doc comment (matches the reference contract).
        assert!(serde_json::from_str::<StartMessage>("not json").is_err());
        assert!(serde_json::from_str::<StartMessage>(r#"{"type":"begin"}"#).is_err());
        assert!(serde_json::from_str::<StartMessage>(r#"{"type":"start","x":1}"#).is_ok());
    }

    #[test]
    fn infer_response_rejects_unknown_fields() {
        let ok = r#"{"rms":1.0,"zero_crossings":2,"checksum":3,"samples":4,"transcript":"now","audio_bytes":640}"#;
        assert!(serde_json::from_str::<InferResponse>(ok).is_ok());
        let extra = r#"{"rms":1.0,"zero_crossings":2,"checksum":3,"samples":4,"transcript":"now","audio_bytes":640,"x":1}"#;
        assert!(serde_json::from_str::<InferResponse>(extra).is_err());
    }

    #[test]
    fn partial_serializes_with_type_tag_and_full_field_set() {
        let partial = PartialMessage {
            type_tag: PARTIAL_TYPE,
            oldest_frame_seq: 1,
            newest_frame_seq: 50,
            frames: 50,
            rms: 2425.5,
            zero_crossings: 7,
            checksum: 1_745_339_397,
            samples: 1280,
            transcript: "now".to_owned(),
            audio_bytes: 32000,
            cpu_passes: 4,
            model_delay_ms: 75,
            flush_lateness_ms: 0.0,
            inflight_model_jobs: 0,
        };
        let value: serde_json::Value =
            serde_json::from_slice(&serde_json::to_vec(&partial).unwrap()).unwrap();
        assert_eq!(value["type"], "partial");
        for field in [
            "oldest_frame_seq",
            "newest_frame_seq",
            "frames",
            "rms",
            "zero_crossings",
            "checksum",
            "samples",
            "transcript",
            "audio_bytes",
            "cpu_passes",
            "model_delay_ms",
            "flush_lateness_ms",
            "inflight_model_jobs",
        ] {
            assert!(value.get(field).is_some(), "missing {field}");
        }
    }

    #[test]
    fn error_kind_uses_wire_spelling() {
        let json = serde_json::to_string(&ErrorKind::Http5xx).unwrap();
        assert_eq!(json, r#""http_5xx""#);
    }
}
