use std::time::Instant;

use bytes::{Bytes, BytesMut};

use crate::config::{CPU_PASSES_HEADER, FRAME_BYTES};
use crate::protocol::{
    ERROR_TYPE, ErrorKind, ErrorMessage, ErrorStage, Frame, InferResponse, PartialContext,
    PartialMessage,
};
use crate::state::AppContext;

pub(crate) struct InferenceContext<F: Fn() -> usize> {
    pub(crate) flush_lateness_ms: f64,
    /// Sampler the helper calls *only on the error path* to read
    /// `gateway_buffer_frames`. Avoids locking the buffer mutex on the
    /// happy path where the value is unused.
    pub(crate) gateway_buffer_frames_at_error: F,
}

pub(crate) async fn request_partial<F: Fn() -> usize>(
    context: &AppContext,
    batch: Vec<Frame>,
    inference_context: InferenceContext<F>,
) -> Result<PartialMessage, ErrorMessage> {
    let oldest = batch.first().expect("non-empty batch");
    let newest = batch.last().expect("non-empty batch");
    let oldest_seq = oldest.seq;
    let newest_seq = newest.seq;
    let oldest_received_at = oldest.received_at;
    let newest_received_at = newest.received_at;
    let frames = batch.len();
    let body = concat_pcm(&batch);
    let body_len = body.len() as u64;
    let partial_context = PartialContext {
        oldest_frame_seq: oldest_seq,
        newest_frame_seq: newest_seq,
        frames,
        flush_lateness_ms: inference_context.flush_lateness_ms,
    };

    let started_at = Instant::now();
    let make_error = |stage: ErrorStage,
                      kind: ErrorKind,
                      message: String,
                      inference_status: Option<u16>,
                      retryable: bool|
     -> ErrorMessage {
        let now = Instant::now();
        ErrorMessage {
            r#type: ERROR_TYPE,
            stage,
            kind,
            message,
            oldest_frame_seq: oldest_seq,
            newest_frame_seq: newest_seq,
            frames,
            audio_bytes: body_len,
            oldest_age_ms: duration_ms(now, oldest_received_at),
            newest_age_ms: duration_ms(now, newest_received_at),
            flush_lateness_ms: inference_context.flush_lateness_ms,
            inference_elapsed_ms: Some(duration_ms(now, started_at)),
            // Always 1: the one-inflight-per-connection invariant from CLAUDE.md
            // means we *are* the inflight batch. The field is on-wire so clients
            // can reason about gateway pressure under future relaxed designs.
            inflight_gateway_batches: 1,
            gateway_buffer_frames: (inference_context.gateway_buffer_frames_at_error)(),
            inference_status,
            retryable,
        }
    };

    let response = match context
        .inference_client()
        .post(context.inference_url.as_ref())
        .header(CPU_PASSES_HEADER, context.cpu_passes_header.clone())
        .body(body)
        .send()
        .await
    {
        Ok(response) => response,
        Err(error) => {
            let (kind, retryable) = classify_request_error(&error);
            return Err(make_error(
                ErrorStage::InferenceRequest,
                kind,
                error.to_string(),
                None,
                retryable,
            ));
        }
    };

    let status = response.status();
    if !status.is_success() {
        let (kind, retryable) = classify_status(status.as_u16());
        return Err(make_error(
            ErrorStage::InferenceRequest,
            kind,
            format!("inference returned status {status}"),
            Some(status.as_u16()),
            retryable,
        ));
    }

    let infer: InferResponse = match response.json().await {
        Ok(infer) => infer,
        Err(error) => {
            return Err(make_error(
                ErrorStage::InferenceResponseParse,
                ErrorKind::ParseError,
                error.to_string(),
                Some(status.as_u16()),
                false,
            ));
        }
    };

    Ok(PartialMessage::new(
        infer,
        partial_context,
        context.cpu_passes,
        context.model_delay,
    ))
}

fn concat_pcm(batch: &[Frame]) -> Bytes {
    let mut body = BytesMut::with_capacity(batch.len() * FRAME_BYTES);
    for frame in batch {
        body.extend_from_slice(&frame.payload);
    }
    body.freeze()
}

fn duration_ms(now: Instant, earlier: Instant) -> f64 {
    now.saturating_duration_since(earlier).as_secs_f64() * 1000.0
}

fn classify_request_error(error: &reqwest::Error) -> (ErrorKind, bool) {
    if error.is_timeout() {
        return (ErrorKind::Timeout, true);
    }
    if error.is_connect() {
        return (ErrorKind::ConnectionReset, true);
    }
    if error.is_decode() {
        return (ErrorKind::ParseError, false);
    }
    (ErrorKind::ConnectionReset, true)
}

fn classify_status(status: u16) -> (ErrorKind, bool) {
    if status == 429 {
        return (ErrorKind::Http429, true);
    }
    if (500..600).contains(&status) {
        return (ErrorKind::Http5xx, true);
    }
    (ErrorKind::Http5xx, false)
}
